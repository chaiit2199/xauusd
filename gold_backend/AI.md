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

## Chặn nhận định lặp hoặc lẫn ngôn ngữ

Bộ kiểm tra không còn chấp nhận một đoạn tiếng Anh chỉ vì có một từ tiếng Việt
có dấu. Nhận định phải dài 80–2.400 ký tự; tối thiểu 25% từ diễn giải chứa dấu
tiếng Việt (bỏ qua mã tài sản, chỉ báo và các chữ viết tắt tài chính phổ biến).
Cụm 4–12 từ lặp ít nhất 3 lần và chiếm phần đáng kể của đoạn bị từ chối.
Unicode được chuẩn hóa trước khi kiểm tra.

Nội dung lặp bị từ chối ngay, không đem dịch vì không có lập luận đáng tin cậy
để giữ nguyên. Nội dung chưa đạt yêu cầu tiếng Việt được dịch tối đa một lần;
bản dịch cũng phải qua kiểm tra chất lượng và giữ nguyên action. Các ngưỡng này
là kiểm tra hình thức, không chứng minh nhận định đúng về ngữ nghĩa hoặc số liệu.

Snapshot kiểm tra lại nhận định trước khi công bố. Khi không hợp lệ, kết quả là
`wait`, `ai_action: null`, kèm `ai_error`; không dùng đoạn lỗi làm lý do giao dịch.
Telegram kiểm tra lại toàn bộ nhận định trước khi rút gọn và gửi, kể cả khi
snapshot mang action Buy/Sell và chưa có `ai_error`. Không thay model hay temperature.

## Quy tắc điểm vào: không bán đáy, không mua đỉnh

`EntryRules` là lớp kiểm soát bằng mã, áp dụng cả với action từ AI và tín hiệu
kỹ thuật. Khi vi phạm, `cfd_plan.action` là `wait`; `entry_guard.reasons` giải
thích các điều kiện chưa đạt trên giao diện. AI không có quyền bỏ qua lớp này.
Các khóa do dữ liệu khởi tạo, lịch tin, tin mạnh và đảo chiều chữ V vẫn giữ nguyên.

| Điều kiện | SELL | BUY |
| --- | --- | --- |
| Xu hướng | Giá < SMA20, MACD < 0 | Giá > SMA20, MACD > 0 |
| Chặn RSI cực đoan | RSI < 35 | RSI > 65 |
| Chặn Stochastic | %K < 30 | %K > 75 |
| RSI cho điểm vào | 45–55, gồm hai biên | 45–50, gồm hai biên |
| Bollinger | Giá ≤ dải dưới + 0,25 ATR | Giá ≥ dải trên − 0,25 ATR |
| Xa SMA20 | SMA20 − giá > 2 ATR | Giá − SMA20 > 2 ATR |
| Vùng cản đối diện | Cách S1/Pivot phía dưới ≤ 0,25 ATR | Cách R1/Pivot phía trên ≤ 0,25 ATR |
| Vị trí chờ vào | Trong 0,5 ATR của SMA20 hoặc S1 đã retest | Trong 0,5 ATR của SMA20 hoặc R1 đã retest |

Nếu giá đã thủng S1 hoặc vượt R1, cần quan sát lần lượt phá mức → quay lại trong
±0,25 ATR → tiếp diễn qua mức hơn 0,25 ATR. Dùng các báo giá thị trường thật,
sắp theo thời gian trong 90 phút; không suy ra retest từ High/Low. Thiếu chuỗi
hoặc chuỗi bắt đầu sau lúc phá mức thì chưa xác nhận được retest. Một lần phá
mới sau khi giá quay lại phía đối diện làm mất xác nhận cũ. Đây là xác nhận trên
mẫu giá; hệ thống chưa có OHLC để tự xác nhận mẫu nến H1.

Khi chờ, chỉ hiện kịch bản cùng xu hướng: Sell Limit phía trên giá hiện tại hoặc
Buy Limit phía dưới, quanh SMA20 trong 0,5 ATR. SL/TP tham chiếu tính lại từ vùng
chờ; không tạo kịch bản bắt đáy ngược xu hướng. Các kịch bản chưa phải lệnh đã đặt
và vẫn yêu cầu kiểm tra lại điều kiện, xác nhận nến H1 trước khi sử dụng. Dữ liệu
khởi tạo không xuất vùng đặt lệnh chờ.

Quy ước 0,25 / 0,5 / 2 ATR cụ thể hóa các khái niệm “sát vùng”, “hồi về” và “quá
xa”; đây là tham số chiến lược, chưa phải kết quả tối ưu hoặc backtest. ATR hiện
là trung bình biến động giá đóng cửa H1, không phải True Range từ OHLC; dùng sàn
0,5 USD giống phép tính SL hiện có. Mọi vùng giá tính từ dữ liệu hiện tại.

Quá mua/quá bán không bảo đảm đảo chiều; mục tiêu của bộ lọc là tránh vào đuổi,
không chứng minh một lệnh chắc chắn có lợi nhuận. Tham khảo
[Fidelity về RSI trong xu hướng mạnh](https://www.fidelity.com/learning-center/trading-investing/technical-analysis/technical-indicator-guide/RSI).

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
