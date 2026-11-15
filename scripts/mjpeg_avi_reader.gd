class_name MjpegAviReader extends RefCounted
## M-F GAMEPLAY RECORDER — the verification side.
##
## Parses an AVI produced by MjpegAviWriter (or any RIFF/MJPG AVI) and decodes
## its frames with Godot's own JPEG decoder. This is what the recorder uses to
## prove a finished recording is a real, decodable video before it reports
## success, and what the automated tests use to check dimensions, frame order,
## frame rate and duration.
##
## Everything is read defensively: a truncated/corrupt file returns
## {"ok": false, "err": "..."} instead of raising, and no assumption about the
## header offsets is made — chunks are walked, not indexed by position.

## {"ok", "err", "width", "height", "fps", "frames", "duration", "bytes",
##  "chunks": [{offset, size}], "index_entries", "codec"}
static func inspect(path: String) -> Dictionary:
	var out := {"ok": false, "err": "", "width": 0, "height": 0, "fps": 0.0,
		"frames": 0, "duration": 0.0, "bytes": 0, "chunks": [], "index_entries": 0,
		"codec": "", "movi_base": 0}
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		out["err"] = "cannot open '%s' (error %d)" % [path, FileAccess.get_open_error()]
		return out
	out["bytes"] = int(f.get_length())
	if int(out["bytes"]) < 32:
		out["err"] = "the file is too small to be a video (%d bytes)" % int(out["bytes"])
		f.close()
		return out
	if f.get_buffer(4).get_string_from_ascii() != "RIFF":
		out["err"] = "not a RIFF file"
		f.close()
		return out
	f.get_32()                                  # riff size
	if f.get_buffer(4).get_string_from_ascii() != "AVI ":
		out["err"] = "a RIFF file, but not AVI"
		f.close()
		return out
	_walk(f, int(out["bytes"]), out, 0)
	f.close()
	if str(out["err"]) != "":
		return out
	if int(out["width"]) <= 0 or int(out["height"]) <= 0:
		out["err"] = "the video header has no picture size"
		return out
	if float(out["fps"]) <= 0.0:
		out["err"] = "the video header has no frame rate"
		return out
	if (out["chunks"] as Array).is_empty():
		out["err"] = "the video contains no frames"
		return out
	out["frames"] = (out["chunks"] as Array).size()
	out["duration"] = float(out["frames"]) / float(out["fps"])
	out["ok"] = true
	return out


## Decode one frame (index from 0) to an Image. Returns null on failure and
## stores the reason in `last_error`.
static var last_error := ""


static func decode_frame(path: String, info: Dictionary, index: int) -> Image:
	last_error = ""
	var chunks: Array = info.get("chunks", [])
	if index < 0 or index >= chunks.size():
		last_error = "frame %d is out of range (0..%d)" % [index, chunks.size() - 1]
		return null
	var chunk: Dictionary = chunks[index]
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		last_error = "cannot open the video for reading"
		return null
	f.seek(int(info.get("movi_base", 0)) + int(chunk.get("offset", -1)))
	var id := f.get_buffer(4).get_string_from_ascii()
	var size := int(f.get_32())
	if size != int(chunk.get("size", -1)):
		last_error = "frame %d chunk size mismatch (%d vs %d)" % [index, size, int(chunk.get("size", -1))]
		f.close()
		return null
	if not (id == "00dc" or id == "00db"):
		last_error = "frame %d is not a video chunk ('%s')" % [index, id]
		f.close()
		return null
	if size <= 0 or size > 64 * 1024 * 1024:
		last_error = "frame %d has an implausible size (%d)" % [index, size]
		f.close()
		return null
	var bytes := f.get_buffer(size)
	f.close()
	var img := Image.new()
	if img.load_jpg_from_buffer(bytes) != OK:
		last_error = "frame %d could not be decoded as JPEG" % index
		return null
	if img.get_width() != int(info.get("width", 0)) or img.get_height() != int(info.get("height", 0)):
		last_error = "frame %d is %dx%d, the header says %dx%d" % [index,
			img.get_width(), img.get_height(), int(info.get("width", 0)), int(info.get("height", 0))]
		return null
	return img


## Decode frames 0..count-1 (or all when count < 0). Returns {ok, err, decoded,
## first, last}. `first`/`last` are Images, kept out of JSON output on purpose.
static func decode_all(path: String, info: Dictionary, count := -1) -> Dictionary:
	var n: int = int(info.get("frames", 0)) if count < 0 else mini(count, int(info.get("frames", 0)))
	var out := {"ok": true, "err": "", "decoded": 0, "first": null, "last": null}
	if n <= 0:
		out["ok"] = false
		out["err"] = "no frames to decode"
		return out
	for i in n:
		var img := decode_frame(path, info, i)
		if img == null:
			out["ok"] = false
			out["err"] = last_error
			return out
		if i == 0:
			out["first"] = img
		out["last"] = img
		out["decoded"] = i + 1
	return out


## Walk RIFF chunks. Recognises hdrl (avih/strh/strf) and movi (video chunks),
## records the index chunk, and stops at the first structural problem.
static func _walk(f: FileAccess, file_end: int, out: Dictionary, depth: int) -> void:
	if depth > 4:
		out["err"] = "RIFF nesting is too deep to be a valid AVI"
		return
	while f.get_position() + 8 <= file_end:
		var id := f.get_buffer(4).get_string_from_ascii()
		if id.length() < 4:
			out["err"] = "unexpected end of the AVI at byte %d" % (f.get_position() - 4)
			return
		var size := int(f.get_32())
		var data := f.get_position()
		if size < 0 or data + size > file_end:
			out["err"] = "chunk '%s' at byte %d claims %d bytes, past the end of the file" % [id, data - 8, size]
			return
		if id == "LIST":
			var subtype := f.get_buffer(4).get_string_from_ascii()
			if subtype == "movi":
				out["movi_base"] = data      # offset zero of the index
			_walk(f, data + size, out, depth + 1)
		elif id == "avih":
			_parse_avih(f, out, size)
		elif id == "strh":
			_parse_strh(f, out, size)
		elif id == "strf":
			_parse_strf(f, out, size)
		elif id == "idx1":
			var entries := size / 16
			out["index_entries"] = entries
		elif id == "00dc" or id == "00db":
			# offset is FROM the 'movi' FOURCC to the chunk HEADER (id + size),
			# the same convention idx1 uses, so decode_frame can seek there
			var base := int(out.get("movi_base", data - 8))
			out["chunks"].append({"offset": (data - 8) - base, "size": size})
		f.seek(data + size + (size & 1))
	if f.get_position() < file_end and f.get_position() + 8 > file_end:
		# A single trailing pad byte is legal; anything else was reported above.
		pass


static func _parse_avih(f: FileAccess, out: Dictionary, size: int) -> void:
	if size < 40:
		out["err"] = "avih chunk is truncated"
		return
	f.get_32()                                  # usec per frame
	f.get_32()                                  # max bytes/sec
	f.get_32()                                  # padding granularity
	f.get_32()                                  # flags
	var frames := int(f.get_32())
	out["header_frames"] = frames
	f.get_32()                                  # initial frames
	f.get_32()                                  # streams
	f.get_32()                                  # suggested buffer
	var w := int(f.get_32())
	var h := int(f.get_32())
	if w > 0:
		out["width"] = w
	if h > 0:
		out["height"] = h


static func _parse_strh(f: FileAccess, out: Dictionary, size: int) -> void:
	if size < 48:
		out["err"] = "strh chunk is truncated"
		return
	var kind := f.get_buffer(4).get_string_from_ascii()
	var handler := f.get_buffer(4).get_string_from_ascii()
	if kind != "vids":
		return
	out["codec"] = handler
	f.get_32()                                  # flags
	f.get_16()                                  # priority
	f.get_16()                                  # language
	f.get_32()                                  # initial frames
	var scale := int(f.get_32())
	var rate := int(f.get_32())
	if scale > 0 and rate > 0:
		out["fps"] = float(rate) / float(scale)


static func _parse_strf(f: FileAccess, out: Dictionary, size: int) -> void:
	if size < 20:
		out["err"] = "strf chunk is truncated"
		return
	var bi_size := int(f.get_32())
	if bi_size < 40:
		out["err"] = "the video format header is not a BITMAPINFOHEADER"
		return
	var w := int(f.get_32())
	var h := int(f.get_32())
	var planes := int(f.get_16())
	var bits := int(f.get_16())
	var comp := f.get_buffer(4).get_string_from_ascii()
	if w > 0 and h != 0:
		out["width"] = w
		out["height"] = absi(h)
	if planes != 1 or bits != 24:
		out["degraded"] = true
	if comp != "" and comp != "MJPG" and comp != "mjpg":
		out["codec"] = comp
