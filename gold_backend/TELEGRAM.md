# Nhận định Telegram chuẩn bị sớm

`PLAN_READY` chuẩn bị nhận định trong tác vụ nền; không gửi Telegram ở trạng thái này.
Khi `READY_TO_ENTER`, dùng lại nhận định hợp lệ cùng setup, chu kỳ M15, model và dữ liệu phân tích.
Cache trong RAM chỉ giữ tối đa 256 mục, hết hạn tại mốc M15 tiếp theo; lỗi AI không được cache.
Các tác vụ đồng thời cùng setup dùng chung kết quả, không giữ kết nối DB trong lúc chờ model.
Quote hiện tại không nằm trong khóa cache; tin mới, chỉ báo hoặc mức SL/TP thay đổi tạo khóa mới.
Trước gửi luôn lấy lại quote và chạy lại hard rule; đổi setup/hướng/SL/TP hoặc entry không đạt thì bỏ gửi.

Cấu hình riêng (không dùng `OLLAMA_TIMEOUT_MS` của nhận định dài):

```bash
export OLLAMA_ENTRY_BRIEF_TIMEOUT_MS=90000
export OLLAMA_ENTRY_BRIEF_NUM_PREDICT=450
```

Đây là receive timeout của Ollama, không phải thời hạn dùng giá cũ. Payload rút gọn gồm setup,
chỉ báo cần thiết, tối đa 6 tiêu đề mới nhất hôm nay/hôm qua UTC (180 ký tự/tiêu đề), tối đa 6 sự kiện.
`think: false`; tên H1, M15, EMA20, RSI14 được chấp nhận. Mức giá, tỷ lệ hoặc số độc lập trong
ba câu vẫn bị từ chối để không gửi số liệu AI tự đặt hoặc giá cũ.

Log `entry_alert` có `setup_id`, `stage`, `result`, `reason`; các bước gồm `ai`, `validation`,
`cache`, `prepare`, `context`, `quote`, `revalidation`, `delivery`, `dedup`, `exception`.
Timeout có `stage=entry_brief` và `entry_brief_timeout`; JSON rỗng, lỗi JSON, hết token và
lỗi từng mục có lý do riêng. Không ghi nội dung thinking hay credential vào log.

Sau triển khai image mới, tạo lại container để nạp biến môi trường; chỉ restart không nạp `env.sh`.
Không cần migration cho cache này. Kiểm tra cấu hình an toàn:

```bash
docker exec xauusd-api-1 /app/bin/gold_backend rpc 'IO.inspect(Application.get_env(:gold_backend, :ollama, []) |> Keyword.take([:model, :entry_brief_timeout_ms, :entry_brief_num_predict]))'
docker logs --since 30m xauusd-api-1 2>&1 | grep -E 'entry_alert|stage=entry_brief|telegram_entry_delivery'
```

> Nội dung READY_TO_ENTER hiện dùng ba câu AI: Lý do / Cơ hội / Rủi ro.
> Ollama nhận setup, chỉ báo và tối đa 6 tin hôm nay/hôm qua UTC, `think: false`;
> chỉ lấy JSON phản hồi đã kiểm tra, không lấy trường thinking. AI không thay hướng hoặc SL/TP.
> Sau AI, lấy lại quote và chạy lại rule. Setup đổi, giá không đạt, hết chu kỳ hoặc AI lỗi thì bỏ lần gửi;
> chỉ ghi chống trùng khi Telegram chấp nhận. Lượt đánh giá sau có thể thử lại.
> Không có câu viết sẵn thay thế nội dung AI. Website dùng lại phần giải thích để tránh gọi model hai lần.

> Telegram hiện chỉ gửi `READY_TO_ENTER` khi quote mới và các hard rule entry đạt.
> `PLAN_READY`, `WAIT_RETEST`, `PRICE_MOVED`, `INVALIDATED`, `EXPIRED` chỉ cập nhật trên website.
> Mỗi setup chỉ gửi READY_TO_ENTER thành công một lần; gửi lỗi được thử lại khi vẫn đủ điều kiện.

# Telegram trên Docker/Jenkins

Dockerfile không sao chép `rel/`, vì vậy cấu hình trong `rel/env.sh.eex` không
được đưa vào image. Docker Compose nhận thông tin bot từ `env.sh` trên VPS.
Luồng hiện hành (`scalp-v12-plan-first`): phát `PLAN_READY` khi setup M15 đã
xác nhận và vượt qua các kiểm tra bắt buộc, trước khi chờ quote realtime hoặc AI.
Plan không có nghĩa là vào ngay. Quote mới kiểm tra entry và chuyển sang
`READY_TO_ENTER`, `WAIT_RETEST`, `PRICE_MOVED` hoặc `INVALIDATED`.
AI cung cấp ba mục giải thích bắt buộc trước khi gửi Telegram. SL/TP giữ theo cấu trúc gốc.

Mỗi setup/event đã gửi thành công được lưu vào `strategy_notifications` để chống
lặp qua lần refresh/restart. Lỗi gửi được thử lại khi đánh giá tiếp theo; setup hết
hạn/vô hiệu không được phát lại plan. Đây là chống lặp theo trạng thái lưu trong DB,
không bảo đảm exactly-once nếu tiến trình chết sau khi Telegram nhận nhưng trước
khi DB commit. Thông báo không xác nhận lệnh đã khớp.

Khung gửi mặc định `TELEGRAM_NOTIFY_HOURS=all`. Có thể đặt `14-22` hoặc `22-7`
(giờ Việt Nam); cấu hình cửa sổ này vẫn được tôn trọng. Giờ ưu tiên giao dịch chỉ
là cảnh báo. Plan còn hợp lệ có thể được gửi khi cửa sổ thông báo mở lại.
Bản này cần migration tạo `strategy_notifications` trước khi chạy API mới.

1. Trên VPS, sửa `/home/deploy_user/xauusd/env.sh`, đặt đủ hai biến bằng giá trị
   thật (không đưa token vào Git hoặc log):

   ```bash
   export TELEGRAM_BOT_TOKEN='...'
   export TELEGRAM_CHAT_ID='...'
   export TELEGRAM_NOTIFY_HOURS='all'
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
5. Đợi setup M15 được xác nhận; điều kiện phát tín hiệu kiểm tra lại mỗi phút, rồi xem log.
   Kiểm tra `plan_status` và `plan_blockers`: `action=wait` vẫn có thể có `PLAN_READY`.

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
