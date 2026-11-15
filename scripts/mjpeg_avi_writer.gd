class_name MjpegAviWriter extends RefCounted
## M-F GAMEPLAY RECORDER — the container side.
##
## Writes a Motion-JPEG **AVI** (RIFF): every frame is a complete JPEG produced
## by Godot's own encoder (`Image.save_jpg_to_buffer`), muxed into a standard
## AVI stream that Windows Media Player / VLC / YouTube all decode. This is the
## same shape Godot's own Movie Maker writes (AVI, MJPG video), so no custom
## video ENCODER is written here — only the ~200 bytes of container around
## frames Godot already encoded.
##
## Why not `--write-movie`? Movie Maker is a STARTUP flag: it records the whole
## process, cannot be started/stopped from the game's UI, and would also record
## menus and the Studio. The recorder in this milestone has to be driven by a
## button during a race, so the game captures its own viewport and muxes it.
##
## Wire format (all little-endian):
##   RIFF <size> AVI
##     LIST hdrl
##       avih (56)
##       LIST strl
##         strh (56)   vids / MJPG
##         strf (40)   BITMAPINFOHEADER, biCompression 'MJPG'
##     LIST movi       00dc <len> <jpeg bytes...>
##     idx1            one 16-byte entry per frame
##
## Frames are appended as they arrive (streaming, no in-memory frame list), and
## only the 16-byte index entries are kept so the file can be finalised without
## re-reading it. The header sizes are patched at finish().

const RIFF_SIZE_POS := 4
const MOVI_SIZE_POS := 216
const MOVI_DATA_POS := 224        # first '00dc' chunk header
const AVIH_POS := 32
const STRH_POS := 108
const STRF_POS := 172

var path := ""
var width := 0
var height := 0
var fps := 30.0
var frame_count := 0
var err := ""

var _f: FileAccess = null
var _index: Array = []            # flat [offset, size, offset, size, ...]
var _movi_bytes := 0
var _biggest := 0


## "" on success, otherwise a human-readable reason. Never leaves a half-open
## handle: a failed open means nothing was written.
func open(p_path: String, p_width: int, p_height: int, p_fps: float) -> String:
	close_quietly()
	path = p_path
	width = p_width
	height = p_height
	fps = p_fps
	frame_count = 0
	_index = []
	_movi_bytes = 0
	_biggest = 0
	err = ""
	if width <= 0 or height <= 0:
		err = "invalid video size %dx%d" % [width, height]
		return err
	if fps <= 0.0 or fps > 240.0:
		err = "invalid frame rate %s" % str(fps)
		return err
	_f = FileAccess.open(path, FileAccess.WRITE)
	if _f == null:
		err = "cannot create '%s' (error %d)" % [path, FileAccess.get_open_error()]
		return err
	_write_header()
	return ""


## Append one already-encoded JPEG. The bytes are validated as a JPEG stream
## (SOI marker) before they are written, so a truncated frame can never be
## muxed as if it were a picture.
func add_jpeg(bytes: PackedByteArray) -> String:
	if _f == null:
		return "the video file is not open"
	if bytes.size() < 4 or bytes[0] != 0xFF or bytes[1] != 0xD8:
		return "frame %d is not a JPEG" % frame_count
	var n := bytes.size()
	var off := _movi_bytes + 4    # relative to the 'movi' FOURCC
	_f.store_buffer("00dc".to_ascii_buffer())
	_f.store_32(n)
	_f.store_buffer(bytes)
	if (n & 1) == 1:
		_f.store_8(0)             # RIFF chunks are word aligned
	_index.append(off)
	_index.append(n)
	_movi_bytes += 8 + n + (n & 1)
	if n > _biggest:
		_biggest = n
	frame_count += 1
	if _f.get_error() != OK:
		err = "writing the video file failed (disk full or removed)"
		return err
	return ""


## Write the index and patch every size/count the header declared. Returns ""
## only when the complete file is on disk.
func finish() -> String:
	if _f == null:
		return "the video file is not open"
	if frame_count <= 0:
		close_quietly()
		return "no frames were written"
	var idx_pos := _f.get_position()
	_f.store_buffer("idx1".to_ascii_buffer())
	_f.store_32(_index.size() / 2 * 16)
	var i := 0
	while i < _index.size():
		_f.store_buffer("00dc".to_ascii_buffer())
		_f.store_32(0x00000010)   # AVIIF_KEYFRAME (every MJPEG frame is one)
		_f.store_32(int(_index[i]))
		_f.store_32(int(_index[i + 1]))
		i += 2
	var end_pos := _f.get_position()
	# --- patch what only the finished file knows ---------------------------
	var usec := int(round(1000000.0 / fps))
	_f.seek(RIFF_SIZE_POS)
	_f.store_32(end_pos - 8)
	_f.seek(MOVI_SIZE_POS)
	_f.store_32(4 + _movi_bytes)          # 'movi' FOURCC + chunks
	_f.seek(AVIH_POS)
	_f.store_32(usec)
	_f.store_32(maxi(1, _biggest) * int(fps))
	_f.store_32(0)
	_f.store_32(0x00000010)               # AVIF_HASINDEX
	_f.store_32(frame_count)
	_f.store_32(0)
	_f.store_32(1)                        # dwStreams
	_f.store_32(_biggest)
	_f.store_32(width)
	_f.store_32(height)
	_f.seek(AVIH_POS + 40)                # dwReserved[4]
	_f.store_32(0)
	_f.store_32(0)
	_f.store_32(0)
	_f.store_32(0)
	_f.seek(STRH_POS + 32)                # dwLength
	_f.store_32(frame_count)
	_f.seek(STRH_POS + 36)
	_f.store_32(_biggest)
	_f.seek(STRH_POS + 52)                # rcFrame right/bottom
	_f.store_16(width)
	_f.store_16(height)
	_f.seek(STRF_POS + 4)                 # biWidth / biHeight
	_f.store_32(width)
	_f.store_32(height)
	_f.seek(STRF_POS + 20)                # biSizeImage
	_f.store_32(_biggest)
	if _f.get_error() != OK:
		err = "finalising the video file failed (disk full or removed)"
		close_quietly()
		return err
	_f.flush()
	_f.close()
	_f = null
	if not FileAccess.file_exists(path):
		err = "the video file disappeared before it could be checked"
		return err
	var size := _file_size(path)
	if size < MOVI_DATA_POS + 8:
		err = "the video file is too small (%d bytes)" % size
		return err
	if idx_pos <= 0:
		err = "the video index was not written"
		return err
	return ""


func close_quietly() -> void:
	if _f != null:
		_f.close()
		_f = null


func bytes_written() -> int:
	return _file_size(path) if path != "" else 0


static func _file_size(p: String) -> int:
	var f := FileAccess.open(p, FileAccess.READ)
	if f == null:
		return 0
	var n := f.get_length()
	f.close()
	return int(n)


## The empty-but-valid header, written once. All values that depend on the
## finished stream start as zero and are patched by finish().
func _write_header() -> void:
	var b := PackedByteArray()
	b.resize(MOVI_DATA_POS)
	b.fill(0)
	_put(b, 0, "RIFF")
	_put_u32(b, 4, 0)
	_put(b, 8, "AVI ")
	_put(b, 12, "LIST")
	_put_u32(b, 16, 192)
	_put(b, 20, "hdrl")
	_put(b, 24, "avih")
	_put_u32(b, 28, 56)
	_put_u32(b, AVIH_POS + 0, 0)             # dwMicroSecPerFrame (finish)
	_put_u32(b, AVIH_POS + 8, 0)             # dwPaddingGranularity
	_put_u32(b, AVIH_POS + 12, 0x10)         # AVIF_HASINDEX
	_put_u32(b, AVIH_POS + 24, 1)            # dwStreams
	_put_u32(b, AVIH_POS + 32, width)        # dwWidth
	_put_u32(b, AVIH_POS + 36, height)       # dwHeight
	_put(b, 88, "LIST")
	_put_u32(b, 92, 116)
	_put(b, 96, "strl")
	_put(b, 100, "strh")
	_put_u32(b, 104, 56)
	_put(b, STRH_POS + 0, "vids")
	_put(b, STRH_POS + 4, "MJPG")
	_put_u32(b, STRH_POS + 20, 1)            # dwScale
	_put_u32(b, STRH_POS + 24, int(round(fps)))   # dwRate
	_put_u32(b, STRH_POS + 40, 0xFFFFFFFF)   # dwQuality (default)
	_put_u32(b, STRH_POS + 44, 0)            # dwSampleSize
	_put_u16(b, STRH_POS + 48, 0)            # rcFrame.left
	_put_u16(b, STRH_POS + 50, 0)            # rcFrame.top
	_put_u16(b, STRH_POS + 52, width)        # rcFrame.right
	_put_u16(b, STRH_POS + 54, height)       # rcFrame.bottom
	_put(b, 164, "strf")
	_put_u32(b, 168, 40)
	_put_u32(b, STRF_POS + 0, 40)            # biSize
	_put_u32(b, STRF_POS + 4, width)         # biWidth
	_put_u32(b, STRF_POS + 8, height)        # biHeight
	_put_u16(b, STRF_POS + 12, 1)            # biPlanes
	_put_u16(b, STRF_POS + 14, 24)           # biBitCount
	_put(b, STRF_POS + 16, "MJPG")
	_put(b, 212, "LIST")
	_put_u32(b, MOVI_SIZE_POS, 4)            # 'movi' FOURCC only, patched later
	_put(b, 220, "movi")
	_f.store_buffer(b)


static func _put(b: PackedByteArray, at: int, text: String) -> void:
	var raw := text.to_ascii_buffer()
	for i in raw.size():
		b[at + i] = raw[i]


static func _put_u16(b: PackedByteArray, at: int, v: int) -> void:
	b.encode_u16(at, v & 0xFFFF)


static func _put_u32(b: PackedByteArray, at: int, v: int) -> void:
	b.encode_u32(at, v & 0xFFFFFFFF)
