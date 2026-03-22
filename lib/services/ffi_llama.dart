// ignore_for_file: camel_case_types, non_constant_identifier_names
import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:io';
import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:ebird_generator/services/halp_probe.dart';

// ---------------------------------------------------------------------------
// Opaque C structs — model/context/mtmd pointers
// ---------------------------------------------------------------------------
final class _llama_model   extends ffi.Opaque {}
final class _llama_context extends ffi.Opaque {}
final class _mtmd_context  extends ffi.Opaque {}
final class _mtmd_bitmap   extends ffi.Opaque {}
final class _mtmd_input_chunks extends ffi.Opaque {}

// ---------------------------------------------------------------------------
// _mtmd_input_text — small stable struct, safe to define in Dart
// ---------------------------------------------------------------------------
final class _mtmd_input_text extends ffi.Struct {
  external ffi.Pointer<ffi.Char> text;
  @ffi.Bool() external bool add_special;
  @ffi.Bool() external bool parse_special;
}

// ---------------------------------------------------------------------------
// NOTE: llama_model_params, llama_context_params, and mtmd_context_params
// are intentionally NOT mirrored in Dart. Their layouts change with each
// llama.cpp release. Instead we use the C shim (linux/llama_shim/llama_shim.c)
// which allocates them at the correct native size and exposes field setters.
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// C typedef → Dart typedef  (backend, free)
// ---------------------------------------------------------------------------
typedef _BackendInitC    = ffi.Void Function();
typedef _BackendInitDart = void Function();

typedef _FreeCtxC    = ffi.Void Function(ffi.Pointer<_llama_context>);
typedef _FreeCtxDart = void Function(ffi.Pointer<_llama_context>);

typedef _FreeModelC    = ffi.Void Function(ffi.Pointer<_llama_model>);
typedef _FreeModelDart = void Function(ffi.Pointer<_llama_model>);

typedef _GetLogitsIthC    = ffi.Pointer<ffi.Float> Function(ffi.Pointer<_llama_context>, ffi.Int32);
typedef _GetLogitsIthDart = ffi.Pointer<ffi.Float> Function(ffi.Pointer<_llama_context>, int);

// Shim: allocate & fill params blobs on the native side
typedef _ShimParamsSizeDart  = int  Function();
typedef _ShimParamsSizeC     = ffi.Size Function();
typedef _ShimDefaultDart     = void Function(ffi.Pointer<ffi.Void>);
typedef _ShimDefaultC        = ffi.Void Function(ffi.Pointer<ffi.Void>);
typedef _ShimSetGpuLayersDart = void Function(ffi.Pointer<ffi.Void>, int);
typedef _ShimSetGpuLayersC    = ffi.Void Function(ffi.Pointer<ffi.Void>, ffi.Int32);
typedef _ShimSetNCtxDart     = void Function(ffi.Pointer<ffi.Void>, int);
typedef _ShimSetNCtxC        = ffi.Void Function(ffi.Pointer<ffi.Void>, ffi.Uint32);
typedef _ShimSetGpuDart      = void Function(ffi.Pointer<ffi.Void>, int);
typedef _ShimSetGpuC         = ffi.Void Function(ffi.Pointer<ffi.Void>, ffi.Int32);

// Shim: create model, context, mtmd via native-side blob
typedef _ShimLoadModelC    = ffi.Pointer<_llama_model>   Function(ffi.Pointer<ffi.Char>,  ffi.Pointer<ffi.Void>);
typedef _ShimLoadModelDart = ffi.Pointer<_llama_model>   Function(ffi.Pointer<ffi.Char>,  ffi.Pointer<ffi.Void>);
typedef _ShimNewCtxC       = ffi.Pointer<_llama_context> Function(ffi.Pointer<_llama_model>, ffi.Pointer<ffi.Void>);
typedef _ShimNewCtxDart    = ffi.Pointer<_llama_context> Function(ffi.Pointer<_llama_model>, ffi.Pointer<ffi.Void>);
typedef _ShimMtmdInitC     = ffi.Pointer<_mtmd_context>  Function(ffi.Pointer<ffi.Char>, ffi.Pointer<_llama_model>, ffi.Pointer<ffi.Void>);
typedef _ShimMtmdInitDart  = ffi.Pointer<_mtmd_context>  Function(ffi.Pointer<ffi.Char>, ffi.Pointer<_llama_model>, ffi.Pointer<ffi.Void>);

// shim: evaluate all tokenized chunks (text+image) into the KV cache
typedef _ShimEvalChunksC    = ffi.Int32 Function(ffi.Pointer<_mtmd_context>, ffi.Pointer<_llama_context>, ffi.Pointer<_mtmd_input_chunks>, ffi.Int32, ffi.Pointer<ffi.Int32>);
typedef _ShimEvalChunksDart = int Function(ffi.Pointer<_mtmd_context>, ffi.Pointer<_llama_context>, ffi.Pointer<_mtmd_input_chunks>, int, ffi.Pointer<ffi.Int32>);

// shim: decode a single token at an explicit KV position with logits enabled
typedef _ShimDecodeTokenC    = ffi.Int32 Function(ffi.Pointer<_llama_context>, ffi.Int32, ffi.Int32);
typedef _ShimDecodeTokenDart = int Function(ffi.Pointer<_llama_context>, int, int);

// mtmd
typedef _MtmdFreeC    = ffi.Void Function(ffi.Pointer<_mtmd_context>);
typedef _MtmdFreeDart = void Function(ffi.Pointer<_mtmd_context>);

typedef _BitmapInitC    = ffi.Pointer<_mtmd_bitmap> Function(ffi.Uint32, ffi.Uint32, ffi.Pointer<ffi.Uint8>);
typedef _BitmapInitDart = ffi.Pointer<_mtmd_bitmap> Function(int, int, ffi.Pointer<ffi.Uint8>);
typedef _BitmapFreeC    = ffi.Void Function(ffi.Pointer<_mtmd_bitmap>);
typedef _BitmapFreeDart = void Function(ffi.Pointer<_mtmd_bitmap>);

typedef _ChunksInitC    = ffi.Pointer<_mtmd_input_chunks> Function();
typedef _ChunksInitDart = ffi.Pointer<_mtmd_input_chunks> Function();
typedef _ChunksFreeC    = ffi.Void Function(ffi.Pointer<_mtmd_input_chunks>);
typedef _ChunksFreeDart = void Function(ffi.Pointer<_mtmd_input_chunks>);

typedef _TokenizeC    = ffi.Int32 Function(ffi.Pointer<_mtmd_context>, ffi.Pointer<_mtmd_input_chunks>, ffi.Pointer<_mtmd_input_text>, ffi.Pointer<ffi.Pointer<_mtmd_bitmap>>, ffi.Size);
typedef _TokenizeDart = int Function(ffi.Pointer<_mtmd_context>, ffi.Pointer<_mtmd_input_chunks>, ffi.Pointer<_mtmd_input_text>, ffi.Pointer<ffi.Pointer<_mtmd_bitmap>>, int);
// _EncodeChunkC/Dart, _ChunksSizeC/Dart, _ChunksGetC/Dart removed — handled inside shim_eval_chunks
typedef _DefaultMarkerC    = ffi.Pointer<ffi.Char> Function();
typedef _DefaultMarkerDart = ffi.Pointer<ffi.Char> Function();

// sampler chain — struct is just 1 bool, stable
final class _llama_sampler extends ffi.Opaque {}
final class _llama_sampler_chain_params extends ffi.Struct {
  @ffi.Bool() external bool no_perf;
}
typedef _SamplerChainParamsC    = _llama_sampler_chain_params Function();
typedef _SamplerChainParamsDart = _llama_sampler_chain_params Function();
typedef _SamplerChainInitC    = ffi.Pointer<_llama_sampler> Function(_llama_sampler_chain_params);
typedef _SamplerChainInitDart = ffi.Pointer<_llama_sampler> Function(_llama_sampler_chain_params);
typedef _SamplerChainAddC    = ffi.Void Function(ffi.Pointer<_llama_sampler>, ffi.Pointer<_llama_sampler>);
typedef _SamplerChainAddDart = void Function(ffi.Pointer<_llama_sampler>, ffi.Pointer<_llama_sampler>);
typedef _SamplerInitTempC    = ffi.Pointer<_llama_sampler> Function(ffi.Float);
typedef _SamplerInitTempDart = ffi.Pointer<_llama_sampler> Function(double);
typedef _SamplerInitDistC    = ffi.Pointer<_llama_sampler> Function(ffi.Uint32);
typedef _SamplerInitDistDart = ffi.Pointer<_llama_sampler> Function(int);
typedef _SamplerSampleC    = ffi.Int32 Function(ffi.Pointer<_llama_sampler>, ffi.Pointer<_llama_context>, ffi.Int32);
typedef _SamplerSampleDart = int Function(ffi.Pointer<_llama_sampler>, ffi.Pointer<_llama_context>, int);
typedef _SamplerFreeC    = ffi.Void Function(ffi.Pointer<_llama_sampler>);
typedef _SamplerFreeDart = void Function(ffi.Pointer<_llama_sampler>);

// vocab
final class _llama_vocab extends ffi.Opaque {}
typedef _ModelGetVocabC    = ffi.Pointer<_llama_vocab> Function(ffi.Pointer<_llama_model>);
typedef _ModelGetVocabDart = ffi.Pointer<_llama_vocab> Function(ffi.Pointer<_llama_model>);
typedef _VocabIsEogC    = ffi.Bool Function(ffi.Pointer<_llama_vocab>, ffi.Int32);
typedef _VocabIsEogDart = bool Function(ffi.Pointer<_llama_vocab>, int);
typedef _VocabNTokensC    = ffi.Int32 Function(ffi.Pointer<_llama_vocab>);
typedef _VocabNTokensDart = int Function(ffi.Pointer<_llama_vocab>);
typedef _TokenToPieceC    = ffi.Int32 Function(ffi.Pointer<_llama_vocab>, ffi.Int32, ffi.Pointer<ffi.Char>, ffi.Int32, ffi.Int32, ffi.Bool);
typedef _TokenToPieceDart = int Function(ffi.Pointer<_llama_vocab>, int, ffi.Pointer<ffi.Char>, int, int, bool);

// _llama_batch struct removed — batch operations handled inside shim_decode_token / shim_eval_chunks
// _BatchGetOneC/Dart and _DecodeBatchC/Dart also removed

// ---------------------------------------------------------------------------
// Result object
// ---------------------------------------------------------------------------
class LlamaResult {
  final String text;
  final List<double> halpScores;

  const LlamaResult(this.text, this.halpScores);

  bool get isHighRisk => HalpProbe.shouldAbortGeneration(halpScores);
}

// ---------------------------------------------------------------------------
// Args bundle for the compute() isolate
// ---------------------------------------------------------------------------
class _InferArgs {
  final String shimSoPath;
  final String llamaSoPath;
  final String mtmdSoPath;
  final String modelPath;
  final String mmprojPath;
  final String prompt;
  final Uint8List imageRgbBytes;
  final int imageWidth;
  final int imageHeight;
  final double temperature;
  final int maxTokens;

  const _InferArgs({
    required this.shimSoPath,
    required this.llamaSoPath,
    required this.mtmdSoPath,
    required this.modelPath,
    required this.mmprojPath,
    required this.prompt,
    required this.imageRgbBytes,
    required this.imageWidth,
    required this.imageHeight,
    required this.temperature,
    required this.maxTokens,
  });
}

// ---------------------------------------------------------------------------
// Top-level synchronous inference (runs inside compute() isolate)
// ---------------------------------------------------------------------------
LlamaResult _runInferenceSync(_InferArgs args) {
  // Load the three libraries. The shim depends on libllama and libmtmd, so
  // load llama + mtmd first so they are already in the linker's address space.
  final llama   = ffi.DynamicLibrary.open(args.llamaSoPath);
  final mtmdLib = ffi.DynamicLibrary.open(args.mtmdSoPath);
  final shim    = ffi.DynamicLibrary.open(args.shimSoPath);

  // ── Backend ────────────────────────────────────────────────────────────────
  final backendInit = llama.lookupFunction<_BackendInitC, _BackendInitDart>('llama_backend_init');

  // ── Shim: params helpers ──────────────────────────────────────────────────
  final modelParamsSize    = shim.lookupFunction<_ShimParamsSizeC,     _ShimParamsSizeDart> ('shim_model_params_size');
  final modelParamsDefault = shim.lookupFunction<_ShimDefaultC,        _ShimDefaultDart>    ('shim_model_params_default');
  final modelSetGpuLayers  = shim.lookupFunction<_ShimSetGpuLayersC,   _ShimSetGpuLayersDart>('shim_model_params_set_gpu_layers');
  final shimLoadModel      = shim.lookupFunction<_ShimLoadModelC,      _ShimLoadModelDart>  ('shim_load_model');

  final ctxParamsSize      = shim.lookupFunction<_ShimParamsSizeC,     _ShimParamsSizeDart> ('shim_ctx_params_size');
  final ctxParamsDefault   = shim.lookupFunction<_ShimDefaultC,        _ShimDefaultDart>    ('shim_ctx_params_default');
  final ctxSetNCtx         = shim.lookupFunction<_ShimSetNCtxC,        _ShimSetNCtxDart>    ('shim_ctx_params_set_n_ctx');
  // shim_ctx_params_set_flash_attn: not called — default params already set AUTO (-1)
  final shimNewCtx         = shim.lookupFunction<_ShimNewCtxC,         _ShimNewCtxDart>     ('shim_new_ctx');

  final mtmdParamsSize     = shim.lookupFunction<_ShimParamsSizeC,     _ShimParamsSizeDart> ('shim_mtmd_params_size');
  final mtmdParamsDefault  = shim.lookupFunction<_ShimDefaultC,        _ShimDefaultDart>    ('shim_mtmd_params_default');
  final mtmdSetGpu         = shim.lookupFunction<_ShimSetGpuC,         _ShimSetGpuDart>     ('shim_mtmd_params_set_gpu');
  final shimMtmdInit       = shim.lookupFunction<_ShimMtmdInitC,       _ShimMtmdInitDart>   ('shim_mtmd_init');
  final shimEvalChunks    = shim.lookupFunction<_ShimEvalChunksC,    _ShimEvalChunksDart>  ('shim_eval_chunks');
  final shimDecodeToken   = shim.lookupFunction<_ShimDecodeTokenC,   _ShimDecodeTokenDart> ('shim_decode_token');

  // ── Llama core ────────────────────────────────────────────────────────────
  final freeCtx   = llama.lookupFunction<_FreeCtxC,        _FreeCtxDart>       ('llama_free');
  final freeModel = llama.lookupFunction<_FreeModelC,       _FreeModelDart>     ('llama_model_free');
  final getLogitsIth = llama.lookupFunction<_GetLogitsIthC, _GetLogitsIthDart>  ('llama_get_logits_ith');

  // sampler
  final samplerChainParams = llama.lookupFunction<_SamplerChainParamsC, _SamplerChainParamsDart>('llama_sampler_chain_default_params');
  final samplerChainInit   = llama.lookupFunction<_SamplerChainInitC,   _SamplerChainInitDart>  ('llama_sampler_chain_init');
  final samplerChainAdd    = llama.lookupFunction<_SamplerChainAddC,    _SamplerChainAddDart>   ('llama_sampler_chain_add');
  final samplerInitTemp    = llama.lookupFunction<_SamplerInitTempC,    _SamplerInitTempDart>   ('llama_sampler_init_temp');
  final samplerInitDist    = llama.lookupFunction<_SamplerInitDistC,    _SamplerInitDistDart>   ('llama_sampler_init_dist');
  final samplerSample      = llama.lookupFunction<_SamplerSampleC,      _SamplerSampleDart>     ('llama_sampler_sample');
  final samplerFree        = llama.lookupFunction<_SamplerFreeC,        _SamplerFreeDart>       ('llama_sampler_free');

  // vocab
  final modelGetVocab = llama.lookupFunction<_ModelGetVocabC,  _ModelGetVocabDart>('llama_model_get_vocab');
  final vocabIsEog    = llama.lookupFunction<_VocabIsEogC,     _VocabIsEogDart>   ('llama_vocab_is_eog');
  final vocabNTokens  = llama.lookupFunction<_VocabNTokensC,   _VocabNTokensDart> ('llama_vocab_n_tokens');
  final tokenToPiece  = llama.lookupFunction<_TokenToPieceC,   _TokenToPieceDart> ('llama_token_to_piece');

  // batch / decode are now handled inside shim_decode_token and shim_eval_chunks

  // ── mtmd ──────────────────────────────────────────────────────────────────
  final mtmdFreeCtx   = mtmdLib.lookupFunction<_MtmdFreeC,    _MtmdFreeDart>   ('mtmd_free');
  final bitmapInit    = mtmdLib.lookupFunction<_BitmapInitC,  _BitmapInitDart> ('mtmd_bitmap_init');
  final bitmapFree    = mtmdLib.lookupFunction<_BitmapFreeC,  _BitmapFreeDart> ('mtmd_bitmap_free');
  final chunksInit    = mtmdLib.lookupFunction<_ChunksInitC,  _ChunksInitDart> ('mtmd_input_chunks_init');
  final chunksFree    = mtmdLib.lookupFunction<_ChunksFreeC,  _ChunksFreeDart> ('mtmd_input_chunks_free');
  final tokenize      = mtmdLib.lookupFunction<_TokenizeC,    _TokenizeDart>   ('mtmd_tokenize');
  // encodeChunk / chunksSize / chunksGet are called inside shim_eval_chunks
  final defaultMarker = mtmdLib.lookupFunction<_DefaultMarkerC, _DefaultMarkerDart>('mtmd_default_marker');

  backendInit();

  // ── Load model via shim (avoids struct layout mismatch) ───────────────────
  final mSz  = modelParamsSize();
  final mBlob = malloc.allocate<ffi.Void>(mSz);
  modelParamsDefault(mBlob);
  modelSetGpuLayers(mBlob, -1); // full GPU offload on RTX 5080

  final modelPathPtr = args.modelPath.toNativeUtf8();
  final modelPtr = shimLoadModel(modelPathPtr.cast(), mBlob);
  malloc.free(modelPathPtr);
  malloc.free(mBlob);

  if (modelPtr == ffi.nullptr) {
    debugPrint('FfiLlama: failed to load model from ${args.modelPath}');
    return const LlamaResult('', []);
  }

  // ── Create inference context via shim ─────────────────────────────────────
  final cSz   = ctxParamsSize();
  final cBlob = malloc.allocate<ffi.Void>(cSz);
  ctxParamsDefault(cBlob);
  ctxSetNCtx(cBlob, 4096);
  // flash_attn_type: AUTO=-1 (default), DISABLED=0, ENABLED=1
  // Default from llama_context_default_params() is already AUTO, no override needed.

  final ctxPtr = shimNewCtx(modelPtr, cBlob);
  malloc.free(cBlob);

  if (ctxPtr == ffi.nullptr) {
    freeModel(modelPtr);
    return const LlamaResult('', []);
  }

  // ── Init multimodal context via shim ─────────────────────────────────────
  final mmSz   = mtmdParamsSize();
  final mmBlob = malloc.allocate<ffi.Void>(mmSz);
  mtmdParamsDefault(mmBlob);
  mtmdSetGpu(mmBlob, 1); // use GPU

  final mmprojPathPtr = args.mmprojPath.toNativeUtf8();
  final mtmdCtx = shimMtmdInit(mmprojPathPtr.cast(), modelPtr, mmBlob);
  malloc.free(mmprojPathPtr);
  malloc.free(mmBlob);

  final halpScores = <double>[];
  final generatedBytes = <int>[];
  String generatedText = '';

  if (mtmdCtx != ffi.nullptr) {
    // ── Upload image pixels ─────────────────────────────────────────────────
    final rgbAlloc = malloc.allocate<ffi.Uint8>(args.imageRgbBytes.length);
    for (int i = 0; i < args.imageRgbBytes.length; i++) {
      rgbAlloc[i] = args.imageRgbBytes[i];
    }
    final bitmap = bitmapInit(args.imageWidth, args.imageHeight, rgbAlloc);
    malloc.free(rgbAlloc);

    if (bitmap != ffi.nullptr) {
      // ── Build prompt with Vicuna (LLaVA v1.5) chat template ───────────────
      // LLaVA-v1.5 is based on Vicuna, which uses the USER:/ASSISTANT: format.
      // Format: A chat... USER: <image>\nPrompt ASSISTANT:
      final markerStr = defaultMarker().cast<Utf8>().toDartString();
      final fullPrompt = 'A chat between a curious human and an artificial intelligence assistant. The assistant gives helpful, detailed, and polite answers to the human\'s questions. USER: $markerStr\n${args.prompt} ASSISTANT:';
      // ── Tokenize text + image chunks ─────────────────────────────────────
      final chunks    = chunksInit();
      final textPtr   = fullPrompt.toNativeUtf8();
      final inputText = malloc.allocate<_mtmd_input_text>(ffi.sizeOf<_mtmd_input_text>());
      inputText.ref.text          = textPtr.cast();
      inputText.ref.add_special   = true;
      inputText.ref.parse_special = true;

      final bitmapArray = malloc.allocate<ffi.Pointer<_mtmd_bitmap>>(ffi.sizeOf<ffi.Pointer<_mtmd_bitmap>>());
      bitmapArray[0] = bitmap;

      tokenize(mtmdCtx, chunks, inputText, bitmapArray, 1);
      malloc.free(bitmapArray);
      malloc.free(textPtr);
      malloc.free(inputText);

      // ── Evaluate all chunks (text → llama_decode, image → CLIP + decode) ──
      final nPastPtr = malloc.allocate<ffi.Int32>(ffi.sizeOf<ffi.Int32>());
      nPastPtr[0] = 0;
      final evalRc = shimEvalChunks(mtmdCtx, ctxPtr, chunks, 512, nPastPtr);
      final nPast = nPastPtr[0];
      malloc.free(nPastPtr);
      chunksFree(chunks);
      bitmapFree(bitmap);

      if (evalRc != 0) {
        debugPrint('FfiLlama: shim_eval_chunks failed rc=$evalRc');
        mtmdFreeCtx(mtmdCtx);
        freeCtx(ctxPtr);
        freeModel(modelPtr);
        return const LlamaResult('', []);
      }

      // ── Token-by-token decode loop ────────────────────────────────────────
      // Correct pattern:
      //   shim_eval_chunks left logits ready → sample token 0
      //   → decode token 0 at pos n_past (logits=1) → sample token 1 → ...
      final smplParams = samplerChainParams();
      final smpl       = samplerChainInit(smplParams);
      samplerChainAdd(smpl, samplerInitTemp(args.temperature));
      samplerChainAdd(smpl, samplerInitDist(0xFFFFFFFF));

      final vocab     = modelGetVocab(modelPtr);
      final vocabSize = vocabNTokens(vocab);
      final pieceBuf  = malloc.allocate<ffi.Char>(256);

      var currentPos = nPast;  // KV position for the next generated token
      var lastToken  = 0;       // last sampled token (used in step > 0 decode)
      for (int step = 0; step < args.maxTokens; step++) {
        // Step 0: logits already ready from shim_eval_chunks
        // Step N>0: decode the previously generated token at its position first
        if (step > 0) {
          // tokenBuf[0] holds the last sampled token; currentPos-1 is its position
          final rc = shimDecodeToken(ctxPtr, lastToken, currentPos - 1);
          if (rc != 0) {
            debugPrint('FfiLlama: shim_decode_token failed rc=$rc at step $step');
            break;
          }
        }

        // Sample the next token from the current logits
        final newToken = samplerSample(smpl, ctxPtr, -1);
        lastToken = newToken;
        currentPos++;

        // HALP: collect entropy of the logit distribution
        final logitsPtr = getLogitsIth(ctxPtr, -1);
        if (logitsPtr != ffi.nullptr) {
          final logitsView = logitsPtr.asTypedList(vocabSize);
          halpScores.add(HalpProbe.estimateRisk(Float32List.fromList(logitsView), vocabSize));
          if (HalpProbe.shouldAbortGeneration(halpScores)) {
            debugPrint('FfiLlama: HALP abort at step $step');
            break;
          }
        }

        final eog = vocabIsEog(vocab, newToken);
        debugPrint('FfiLlama: step $step generated token=$newToken (EOG=$eog)');
        if (eog) break;
        final pieceLen = tokenToPiece(vocab, newToken, pieceBuf, 255, 0, false);
        if (pieceLen > 0) {
          for (int i = 0; i < pieceLen; i++) {
            generatedBytes.add(pieceBuf[i]);
          }
          // Also incrementally compute the string for logs/UI if needed, but for now
          // we just decode at the end.
        }
      }

      generatedText = utf8.decode(generatedBytes, allowMalformed: true);

      malloc.free(pieceBuf);
      samplerFree(smpl);
    }

    mtmdFreeCtx(mtmdCtx);
  }

  freeCtx(ctxPtr);
  freeModel(modelPtr);

  return LlamaResult(generatedText, halpScores);
}

// ---------------------------------------------------------------------------
// Paths to compiled .so files
// ---------------------------------------------------------------------------
class LlamaPaths {
  static const String shimSo   = '/home/jkane/ebird_generator/linux/llama_shim/libllama_shim.so';
  static const String llamaSo  = '/home/jkane/llama.cpp/build/bin/libllama.so';
  static const String mtmdSo   = '/home/jkane/llama.cpp/build/bin/libmtmd.so';

  // LLaVA 7B (liuhaotian/llava-v1.5-7b) — standard llama arch + CLIP mmproj.
  // Confirmed working with llama-mtmd-cli: correctly identified an eagle in test-1.jpeg.
  // The mllama-format llama3.2-vision blobs are NOT supported by llama.cpp's model loader.
  static const String modelGguf =
      '/usr/share/ollama/.ollama/models/blobs/sha256-170370233dd5c5415250a2ecd5c71586352850729062ccef1496385647293868';
  static const String mmproj =
      '/usr/share/ollama/.ollama/models/blobs/sha256-72d6f08a42f656d36b356dbe0920675899a99ce21192fd66266fb7d82ed07539';
}

// ---------------------------------------------------------------------------
// Public service class
// ---------------------------------------------------------------------------
class FfiLlama {
  const FfiLlama();

  Future<LlamaResult> classify(
    String imagePath,
    String prompt, {
    double temperature = 0.1,
    int maxTokens = 96,
  }) async {
    final bytes   = await File(imagePath).readAsBytes();
    final decoded = img.decodeImage(bytes);
    if (decoded == null) {
      debugPrint('FfiLlama: could not decode $imagePath');
      return const LlamaResult('', []);
    }

    final rgbBytes = Uint8List(decoded.width * decoded.height * 3);
    int idx = 0;
    for (final p in decoded) {
      rgbBytes[idx++] = p.r.toInt();
      rgbBytes[idx++] = p.g.toInt();
      rgbBytes[idx++] = p.b.toInt();
    }

    return compute(_runInferenceSync, _InferArgs(
      shimSoPath:    LlamaPaths.shimSo,
      llamaSoPath:   LlamaPaths.llamaSo,
      mtmdSoPath:    LlamaPaths.mtmdSo,
      modelPath:     LlamaPaths.modelGguf,
      mmprojPath:    LlamaPaths.mmproj,
      prompt:        prompt,
      imageRgbBytes: rgbBytes,
      imageWidth:    decoded.width,
      imageHeight:   decoded.height,
      temperature:   temperature,
      maxTokens:     maxTokens,
    ));
  }

  void dispose() {}
}
