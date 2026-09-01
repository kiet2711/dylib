# EasyComix Gemini Dylib Tweak

Tweak nhúng vào IPA EasyComix để tự động dịch truyện bằng Google Gemini API miễn phí và không giới hạn credit.

## Tính Năng Nổi Bật:
- **Chuyển đổi linh hoạt (Bật/Tắt)**: Có nút chuyển nhanh giữa **Gemini AI** và **API Gốc** của EasyComix.
- **Nút nổi thông minh**: 
  - **Chạm 1 lần**: Mở popup quản lý Key Pool, chọn Model, Bật/Tắt dịch.
  - **Nhấn giữ 0.6s**: Bật/Tắt nhanh chế độ (Gemini AI ⇄ API Gốc) kèm thông báo rung & hiển thị Toast.
  - Trạng thái hiển thị trực quan: `🤖 AI` (Màu xanh) khi Bật, `⚡ Gốc` (Màu xám) khi Tắt.
- **Mở khóa PRO Lifetime**: Không giới hạn lượt dịch, không dính Paywall / Login bắt buộc.
- **Tự động xoay Key**: Dán nhiều Gemini API Key để tự động đổi khi gặp lỗi Rate Limit (429).
- **Hỗ trợ Model**: `gemini-2.5-flash-lite` và `gemini-3.5-flash-lite`.

## Tự động Build bằng GitHub Actions
Khi push code lên repository này, GitHub Actions sẽ tự động biên dịch file `EasyComixGemini.dylib` cho kiến trúc `arm64` (iOS 14.0+).

### Cách tải file Dylib sau khi build:
1. Vào tab **Actions** trên GitHub.
2. Chọn workflow chạy mới nhất.
3. Kéo xuống mục **Artifacts** để tải về `EasyComixGemini-dylib.zip`.
4. Giải nén lấy file `EasyComixGemini.dylib` và nhúng vào app.
