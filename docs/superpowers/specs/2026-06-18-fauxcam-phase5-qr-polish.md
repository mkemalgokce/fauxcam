# FauxCam Phase 5 — QR source + polish (final)

**Status:** Spec
**Depends on:** Phases 0–4 (merged)

## 1. Goal

Add a QR-code frame source and finish the product: docs, signing/notarization path.

## 2. Observable behavior

- `faux serve|run --source qr:<text>` feeds a scannable QR code of `<text>` into the simulator camera. A real QR scanner reading the video frames decodes `<text>`.
- `README.md` documents build, the `faux` commands, the source vocabulary, the menubar app, the architecture, and distribution.
- `Scripts/sign-app.sh` assembles and code-signs `FauxCam.app` (ad-hoc by default; Developer ID for distribution) and documents notarization.

## 3. Architecture

- **`QRCodeSource: FrameSource` (FauxAdapters):** renders the payload via `CIFilter.qrCodeGenerator()`, scales it (nearest-neighbour, ~80% with a quiet zone) centered on a white canvas at the demanded size, and produces a BGRA `Frame` through the shared `PixelBufferScaler` (extended with a `CIImage` overload so the QR canvas reuses the same render/copy path). Registered in `FrameSourceFactory` under the `qr:` prefix.
- No new guest code: the QR is delivered as ordinary BGRA frames, so any consumer that reads the video frames (Vision / a barcode detector over the buffer) sees it. Hooking the app's `AVCaptureMetadataOutput` so a metadata-only scanner fires is a larger guest swizzle and is left as a documented future enhancement.

## 4. Testing

- **`QRCodeSourceTests`:** generate a QR frame for a known string, decode it back with `CIDetector(ofType: CIDetectorTypeQRCode)`, assert the message round-trips and the frame is well-formed at the demanded size; `FrameSourceFactory` maps `qr:` to `QRCodeSource`.
- End-to-end (live sim): `faux serve --source qr:<text>` delivers valid BGRA frames to the capture delegate.

## 5. Risks

- QR sharpness through CoreImage scaling — use nearest-neighbour sampling so modules stay crisp and decodable (asserted by the decode round-trip).
- Notarization needs credentials + network; the script signs locally and documents the notarytool/stapler steps rather than performing them.

## 6. Non-goals

No guest `AVCaptureMetadataOutput` hook (documented future work), no DMG packaging beyond the signed `.app`, no `FigCaptureSession` low-level layer (potential Phase 6).
