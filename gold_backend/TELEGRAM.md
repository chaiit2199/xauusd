# Telegram trên Docker/Jenkins

Dockerfile không sao chép `rel/`, vì vậy cấu hình trong `rel/env.sh.eex` không
được đưa vào image. Docker Compose nhận thông tin bot từ `env.sh` trên VPS.
Chỉ gửi khi quyết định cuối cùng (`cfd_plan.action`) là `buy` hoặc `sell` và
không có lỗi AI, và toàn bộ nhận định vượt qua kiểm tra tiếng Việt/chống lặp
trước khi rút gọn tin nhắn. `wait` / “Đứng ngoài” không gửi, kể cả AI đề xuất Buy/Sell
nhưng điều kiện kiểm soát rủi ro đã khóa lệnh.
Nhận định hết chu kỳ M15 không được gửi. Khi chưa cấu hình `GOLD_API_KEY`, nguồn lỗi hoặc chưa đủ 50 nến M15/H1,
tín hiệu giữ `wait`, nên chưa có thông báo Buy/Sell. OHLC được đồng bộ tự động
35 giây sau các mốc đóng nến; xem tiến độ trên giao diện và hướng dẫn trong [AI.md](AI.md).

1. Trên VPS, sửa `/home/deploy_user/xauusd/env.sh`, đặt đủ hai biến bằng giá trị
   thật (không đưa token vào Git hoặc log):

   ```bash
   export TELEGRAM_BOT_TOKEN='...'
   export TELEGRAM_CHAT_ID='...'
   ```

2. Với chat cá nhân, mở đúng bot trong Telegram và gửi `/start`. Nếu dùng
   nhóm/kênh, thêm bot và cho phép bot gửi tin; chat ID phải là ID của nhóm/kênh.
3. Build bản mã mới trong Jenkins với `DEPLOY=production`. Nếu chỉ cập nhật
   `env.sh`, chạy `bash deploy.sh` trong thư mục deploy trên VPS để tạo lại
   container bằng image đã triển khai. `docker restart` không nạp lại các biến
   Compose từ `env.sh`.
4. Kiểm tra cấu hình **đang chạy**, không in token/chat ID:

   ```bash
   docker exec xauusd-api-1 /app/bin/gold_backend rpc \
     'IO.inspect(GoldBackend.Services.TelegramNotifier.configuration_status())'
   ```

   Kết quả cần là `%{configured: true, missing: []}`. Kết quả này xác nhận đủ
   cấu hình; việc Telegram chấp nhận tin được xác nhận bằng log gửi thành công.
5. Đợi một vòng phân tích có kết quả Buy/Sell (chu kỳ 15 phút tại :00/:15/:30/:45), rồi xem log.
   Nếu kết quả là “Đứng ngoài”, không có tin Telegram là hành vi đúng:

   ```bash
   docker logs --since 30m xauusd-api-1 2>&1 | grep -E 'Telegram|Analysis|Ollama|Vietnamese|expired M15'
   ```

   - `Telegram notification delivered`: Telegram đã chấp nhận tin.
   - `Thiếu TELEGRAM_...`: bổ sung biến trong `env.sh` và tạo lại container.
   - `401`: kiểm tra token.
   - `400 ... chat not found`: kiểm tra chat ID và đã gửi `/start` cho đúng bot.
   - `403`: bot bị chặn hoặc thiếu quyền gửi vào nhóm/kênh.
   - `429`: Telegram giới hạn tần suất gửi.
   - `timeout`, `nxdomain`, `network_error`: kiểm tra kết nối HTTPS/DNS/TLS của container.
   - `Analysis failed/stopped/timed out`: chưa tạo được snapshot mới nên chưa
     chạy bước gửi thông báo; xử lý lỗi dữ liệu/phân tích trước.

Bản sửa AI thử chuyển nhận định sang tiếng Việt tối đa một lần bằng cùng model,
dùng `OLLAMA_TRANSLATION_TIMEOUT_MS` riêng, và từ chối bản dịch nếu action thay đổi. Nếu model
vẫn không trả tiếng Việt hợp lệ, hệ thống giữ lỗi và tiếp tục chờ; không tự tạo
quyết định AI thay thế.
