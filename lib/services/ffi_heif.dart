// ignore_for_file: camel_case_types, prefer_interpolation_to_compose_strings
import 'dart:ffi' as ffi;
import 'dart:io';
import 'package:ffi/ffi.dart';
import 'dart:typed_data';

// --- structs ---

final class HeifError extends ffi.Struct {
  @ffi.Uint32()
  external int code;
  @ffi.Uint32()
  external int subcode;
  external ffi.Pointer<Utf8> message;
}

// Opaque pointers
final class HeifContext extends ffi.Opaque {}
final class HeifImageHandle extends ffi.Opaque {}
final class HeifImage extends ffi.Opaque {}

// Enums 
const int _heifColorspaceRgb = 1;
const int _heifChromaInterleavedRgb = 10;
const int _heifChannelInterleaved = 10;

// --- Function Typedefs ---
typedef _heif_context_alloc_C = ffi.Pointer<HeifContext> Function();
typedef _heif_context_alloc_Dart = ffi.Pointer<HeifContext> Function();

typedef _heif_context_free_C = ffi.Void Function(ffi.Pointer<HeifContext>);
typedef _heif_context_free_Dart = void Function(ffi.Pointer<HeifContext>);

typedef _heif_context_read_from_file_C = HeifError Function(
    ffi.Pointer<HeifContext>, ffi.Pointer<Utf8>, ffi.Pointer<ffi.Void>);
typedef _heif_context_read_from_file_Dart = HeifError Function(
    ffi.Pointer<HeifContext>, ffi.Pointer<Utf8>, ffi.Pointer<ffi.Void>);

typedef _heif_context_get_primary_image_handle_C = HeifError Function(
    ffi.Pointer<HeifContext>, ffi.Pointer<ffi.Pointer<HeifImageHandle>>);
typedef _heif_context_get_primary_image_handle_Dart = HeifError Function(
    ffi.Pointer<HeifContext>, ffi.Pointer<ffi.Pointer<HeifImageHandle>>);

typedef _heif_image_handle_release_C = ffi.Void Function(
    ffi.Pointer<HeifImageHandle>);
typedef _heif_image_handle_release_Dart = void Function(
    ffi.Pointer<HeifImageHandle>);

typedef _heif_image_handle_get_width_C = ffi.Int32 Function(
    ffi.Pointer<HeifImageHandle>);
typedef _heif_image_handle_get_width_Dart = int Function(
    ffi.Pointer<HeifImageHandle>);

typedef _heif_image_handle_get_height_C = ffi.Int32 Function(
    ffi.Pointer<HeifImageHandle>);
typedef _heif_image_handle_get_height_Dart = int Function(
    ffi.Pointer<HeifImageHandle>);

typedef _heif_decode_image_C = HeifError Function(
    ffi.Pointer<HeifImageHandle>,
    ffi.Pointer<ffi.Pointer<HeifImage>>,
    ffi.Int32 colorspace,
    ffi.Int32 chroma,
    ffi.Pointer<ffi.Void> options);
typedef _heif_decode_image_Dart = HeifError Function(
    ffi.Pointer<HeifImageHandle>,
    ffi.Pointer<ffi.Pointer<HeifImage>>,
    int colorspace,
    int chroma,
    ffi.Pointer<ffi.Void> options);

typedef _heif_image_release_C = ffi.Void Function(ffi.Pointer<HeifImage>);
typedef _heif_image_release_Dart = void Function(ffi.Pointer<HeifImage>);

typedef _heif_image_get_plane_readonly_C = ffi.Pointer<ffi.Uint8> Function(
    ffi.Pointer<HeifImage>, ffi.Int32 channel, ffi.Pointer<ffi.Int32> stride);
typedef _heif_image_get_plane_readonly_Dart = ffi.Pointer<ffi.Uint8> Function(
    ffi.Pointer<HeifImage>, int channel, ffi.Pointer<ffi.Int32> stride);

// Container for the deep-copied dart bytes
class HeifImagePixels {
  final int width;
  final int height;
  final int stride;
  final Uint8List pixels;

  HeifImagePixels({
    required this.width,
    required this.height,
    required this.stride,
    required this.pixels,
  });
}

class LibHeif {
  static final LibHeif _instance = LibHeif._internal();
  factory LibHeif() => _instance;
  
  late final ffi.DynamicLibrary _lib;
  bool _initialized = false;
  
  late final _heif_context_alloc_Dart _alloc;
  late final _heif_context_free_Dart _free;
  late final _heif_context_read_from_file_Dart _readFromFile;
  late final _heif_context_get_primary_image_handle_Dart _getPrimaryHandle;
  late final _heif_image_handle_release_Dart _releaseHandle;
  late final _heif_image_handle_get_width_Dart _getWidth;
  late final _heif_image_handle_get_height_Dart _getHeight;
  late final _heif_decode_image_Dart _decodeImage;
  late final _heif_image_release_Dart _releaseImage;
  late final _heif_image_get_plane_readonly_Dart _getPlane;

  LibHeif._internal() {
    if (Platform.isWindows) {
      // Try multiple names — NuGet packages use 'libheif.dll', some builds use 'heif.dll'
      final names = ['heif.dll', 'libheif.dll'];
      bool loaded = false;

      // First try simple name (searches exe dir, system PATH, etc.)
      for (final name in names) {
        try {
          _lib = ffi.DynamicLibrary.open(name);
          loaded = true;
          break;
        } catch (_) {
          continue;
        }
      }

      // Then try resolving relative to the executable
      if (!loaded) {
        final exeDir = File(Platform.resolvedExecutable).parent.path;
        for (final name in names) {
          try {
            _lib = ffi.DynamicLibrary.open('$exeDir\\$name');
            loaded = true;
            break;
          } catch (_) {
            continue;
          }
        }
      }

      // Try blobs subdirectory (CMake install puts it there)
      if (!loaded) {
        final exeDir = File(Platform.resolvedExecutable).parent.path;
        for (final name in names) {
          try {
            _lib = ffi.DynamicLibrary.open('$exeDir\\blobs\\$name');
            loaded = true;
            break;
          } catch (_) {
            continue;
          }
        }
      }

      if (!loaded) {
        throw Exception('Failed to open libheif on Windows — tried heif.dll and libheif.dll');
      }
    } else {
      try {
        _lib = ffi.DynamicLibrary.open('libheif.so.1');
      } catch (_) {
        try {
          final libName = Platform.isMacOS ? 'libheif.dylib' : 'libheif.so';
          _lib = ffi.DynamicLibrary.open(libName);
        } catch (e) {
          throw Exception("Failed to open libheif natively: \$e");
        }
      }
    }
    
    _alloc = _lib.lookupFunction<_heif_context_alloc_C, _heif_context_alloc_Dart>('heif_context_alloc');
    _free = _lib.lookupFunction<_heif_context_free_C, _heif_context_free_Dart>('heif_context_free');
    _readFromFile = _lib.lookupFunction<_heif_context_read_from_file_C, _heif_context_read_from_file_Dart>('heif_context_read_from_file');
    _getPrimaryHandle = _lib.lookupFunction<_heif_context_get_primary_image_handle_C, _heif_context_get_primary_image_handle_Dart>('heif_context_get_primary_image_handle');
    _releaseHandle = _lib.lookupFunction<_heif_image_handle_release_C, _heif_image_handle_release_Dart>('heif_image_handle_release');
    _getWidth = _lib.lookupFunction<_heif_image_handle_get_width_C, _heif_image_handle_get_width_Dart>('heif_image_handle_get_width');
    _getHeight = _lib.lookupFunction<_heif_image_handle_get_height_C, _heif_image_handle_get_height_Dart>('heif_image_handle_get_height');
    _decodeImage = _lib.lookupFunction<_heif_decode_image_C, _heif_decode_image_Dart>('heif_decode_image');
    _releaseImage = _lib.lookupFunction<_heif_image_release_C, _heif_image_release_Dart>('heif_image_release');
    _getPlane = _lib.lookupFunction<_heif_image_get_plane_readonly_C, _heif_image_get_plane_readonly_Dart>('heif_image_get_plane_readonly');
    
    _initialized = true;
  }

  /// Extracts the RGB pixel buffer out of a HEIC image via Native C FFI binding
  HeifImagePixels decodeHeic(String path) {
    if (!_initialized) throw Exception("libheif not properly loaded");

    final ctx = _alloc();
    final filenameUtf8 = path.toNativeUtf8();
    
    try {
      final err1 = _readFromFile(ctx, filenameUtf8, ffi.nullptr);
      if (err1.code != 0) {
        final msg = err1.message != ffi.nullptr ? err1.message.toDartString() : 'Unknown';
        throw Exception('libheif read error ' + err1.code.toString() + '/' + err1.subcode.toString() + ': ' + msg);
      }

      final handlePtr = calloc<ffi.Pointer<HeifImageHandle>>();
      try {
        final err2 = _getPrimaryHandle(ctx, handlePtr);
        if (err2.code != 0) {
          final msg = err2.message != ffi.nullptr ? err2.message.toDartString() : 'Unknown';
          throw Exception('libheif handle error ' + err2.code.toString() + ': ' + msg);
        }
        
        final handle = handlePtr.value;
        final w = _getWidth(handle);
        final h = _getHeight(handle);

        final imgPtr = calloc<ffi.Pointer<HeifImage>>();
        try {
          final err3 = _decodeImage(handle, imgPtr, _heifColorspaceRgb, _heifChromaInterleavedRgb, ffi.nullptr);
          if (err3.code != 0) {
            final msg = err3.message != ffi.nullptr ? err3.message.toDartString() : 'Unknown';
            throw Exception('libheif decode error ' + err3.code.toString() + ': ' + msg);
          }
          
          final img = imgPtr.value;
          
          final stridePtr = calloc<ffi.Int32>();
          try {
            final plane = _getPlane(img, _heifChannelInterleaved, stridePtr);
            final stride = stridePtr.value;
            
            // Deep copy C memory into Managed Dart Memory
            final totalBytes = stride * h;
            final cBuffer = plane.asTypedList(totalBytes);
            final dartSafePixels = Uint8List.fromList(cBuffer);

            return HeifImagePixels(
              width: w, 
              height: h, 
              stride: stride, 
              pixels: dartSafePixels
            );
            
          } finally {
            calloc.free(stridePtr);
            _releaseImage(img);
          }
        } finally {
          calloc.free(imgPtr);
          _releaseHandle(handle);
        }
      } finally {
        calloc.free(handlePtr);
      }
    } finally {
      calloc.free(filenameUtf8);
      _free(ctx);
    }
  }
}
