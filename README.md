# EasyComix Gemini Dylib Tweak

Tweak nhúng vào IPA EasyComix để tự động dịch truyện bằng Google Gemini API miễn phí và không giới hạn credit.

## Tự động Build bằng GitHub Actions
Khi push code lên repository này, GitHub Actions sẽ tự động biên dịch file `EasyComixGemini.dylib` cho kiến trúc `arm64` (iOS 14.0+).

### Cách tải file Dylib sau khi build:
1. Vào tab **Actions** trên GitHub.
2. Chọn workflow chạy mới nhất.
3. Kéo xuống mục **Artifacts** để tải về `EasyComixGemini-dylib.zip`.
4. Giải nén lấy file `EasyComixGemini.dylib`.
