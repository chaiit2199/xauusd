# Ollama timeout và nhận định tiếng Việt

Giữ nguyên `OLLAMA_MODEL` hiện tại; mặc định vẫn là `deepseek-r1:1.5b`.
Cả phân tích và sửa tiếng Việt dùng cùng model. Không cần tải model khác.

Trước đây phân tích và dịch chia sẻ một deadline: nếu phân tích gần hết 120 giây,
bước dịch chỉ còn vài giây. Hiện mỗi bước có timeout nhận phản hồi riêng; tác vụ
nền chờ đủ cả hai bước cộng thời gian kết nối và chuẩn bị dữ liệu. Trong lúc tác
vụ đang chạy, hệ thống không mở thêm lượt phân tích tự động chồng lên nó.

Prompt yêu cầu 4 ý ngắn thay cho ít nhất 4 đoạn, chỉ gửi 6 tiêu đề mới nhất và
ưu tiên bản dịch tiêu đề để giảm dữ liệu trùng lặp. Chỉ báo, lịch sự kiện và bản
chấm tin tổng hợp vẫn được gửi. Với DeepSeek-R1, hướng dẫn nằm trong user prompt
và temperature là 0.6 theo
[khuyến nghị của DeepSeek](https://github.com/deepseek-ai/DeepSeek-R1#usage-recommendations).

Kết quả JSON hoàn chỉnh nằm trong code fence hoặc sau phần `<think>...</think>`
được đọc đúng. Nội dung thinking, JSON lỗi, kết quả bị cắt do hết token hoặc bản
dịch đổi action vẫn bị từ chối. Bước dịch chỉ được thử một lần; đây không phải
bảo đảm rằng model luôn trả đúng tiếng Việt.

## Cấu hình trên VPS

Trong `/home/deploy_user/xauusd/env.sh`, giữ nguyên dòng `OLLAMA_MODEL` và thêm
hoặc sửa các biến sau (đơn vị timeout là mili giây):

```bash
export OLLAMA_TIMEOUT_MS=120000
export OLLAMA_TRANSLATION_TIMEOUT_MS=60000
export OLLAMA_NUM_PREDICT=800
```

- `OLLAMA_TIMEOUT_MS`: chờ phản hồi phân tích.
- `OLLAMA_TRANSLATION_TIMEOUT_MS`: chờ phản hồi dịch; không bị trừ thời gian phân tích.
- `OLLAMA_NUM_PREDICT`: giới hạn token mỗi lượt, mặc định giảm từ 1200 còn 800.
  Nếu giao diện báo hết giới hạn sinh nội dung, kiểm tra và tăng giá trị
  này; nhiều token hơn cũng có thể làm thời gian xử lý dài hơn.

Triển khai bản mã mới qua Jenkins với `DEPLOY=production` để cập nhật cả image
và Compose. Sau này khi chỉ sửa `env.sh`, chạy `bash deploy.sh` trong thư mục
deploy để tạo lại container; restart đơn thuần không nạp lại biến Compose.

Đọc cấu hình thực sự trong container (không in token Telegram hay mật khẩu DB):

```bash
docker exec xauusd-api-1 /app/bin/gold_backend rpc \
  'IO.inspect(Application.get_env(:gold_backend, :ollama, []) |> Keyword.take([:model, :timeout_ms, :translation_timeout_ms, :num_predict]))'
```

## Xác định bước bị lỗi

```bash
docker logs --since 15m xauusd-api-1 2>&1 | grep -E 'Ollama|Analysis'
```

Log có `stage=analysis` hoặc `stage=translation`, model, thời gian đã chạy và
thời gian chờ khi request lỗi. Nếu phân tích vẫn vượt 120 giây, cần kiểm tra tải
CPU/RAM và các request khác vào Ollama. Có thể tăng riêng `OLLAMA_TIMEOUT_MS`,
ví dụ 180000; nếu dịch vượt 60 giây, tăng riêng `OLLAMA_TRANSLATION_TIMEOUT_MS`,
ví dụ 90000. Tăng timeout làm kết quả đến muộn hơn; nếu một lượt vượt 5 phút,
hệ thống bỏ qua lượt kích hoạt kế tiếp trong khi lượt hiện tại còn chạy.

Để chạy thử với dữ liệu hiện có mà không cập nhật snapshot dashboard hay gửi
Telegram (tránh chạy nhiều lần đồng thời):

```bash
docker exec xauusd-api-1 /app/bin/gold_backend rpc \
  'result = with {:ok, context} <- GoldBackendWeb.TradingController.build_context(translate_timeout: 8000), do: GoldBackend.Services.AiDecision.analyze(context); IO.inspect(result, limit: :infinity)'
```

Lệnh này vẫn thực hiện các bước chuẩn bị dữ liệu/dịch tiêu đề thường lệ. Kết quả
thành công là `{:ok, action, "nhận định tiếng Việt..."}`; `action` có thể là
`:buy`, `:sell` hoặc `:wait`. `Tin trái chiều` chỉ là nhãn chấm tin, không phải lỗi
tiếng Việt. Telegram chỉ gửi Buy/Sell cuối cùng, không gửi khi chờ hoặc AI lỗi.
