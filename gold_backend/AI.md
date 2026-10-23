# Ollama timeout và nhận định tiếng Việt

Giao diện tập trung trên một trang: bảng giá → nhận định AI → tín hiệu
Mua/Bán/Đứng ngoài → dữ liệu kỹ thuật mở rộng và tin tức. Không còn thanh
điều hướng ba trang, công cụ lập kế hoạch hoặc kịch bản lệnh chờ trên giao diện.
Các mức rủi ro và bộ kiểm tra trong backend vẫn phục vụ phân tích và Telegram.

Thuật ngữ dùng chung trong nhãn tin tức, prompt AI và thông báo:

| Ý nghĩa | Cách diễn đạt |
| --- | --- |
| Yếu tố có tác động tích cực đến giá | Hỗ trợ giá |
| Yếu tố gây sức ép lên giá | Áp lực giảm |
| Thông tin nền, triển vọng kinh tế | Bối cảnh vĩ mô |
| Có hai chiều tác động, chưa bên nào chiếm ưu thế | Tin tức xung đột |
| Chưa đủ điều kiện mở vị thế (`wait`) | Đứng ngoài |

Nhãn tin tức phản ánh phân loại nội dung, không khẳng định giá sẽ đi ngang
hoặc đảo chiều. Tin chỉ có một chiều tác động không mang nhãn xung đột.

Giữ nguyên `OLLAMA_MODEL` hiện tại; mặc định vẫn là `deepseek-r1:1.5b`.
Cả phân tích và sửa tiếng Việt dùng cùng model. Không cần tải model khác.

Trước đây phân tích và dịch chia sẻ một deadline: nếu phân tích gần hết 120 giây,
bước dịch chỉ còn vài giây. Hiện mỗi bước có timeout nhận phản hồi riêng; tác vụ
nền chờ đủ cả hai bước cộng thời gian kết nối và chuẩn bị dữ liệu. Trong lúc tác
vụ đang chạy, hệ thống không mở thêm lượt phân tích tự động chồng lên nó.

Prompt yêu cầu 4 ý ngắn thay cho ít nhất 4 đoạn, chỉ gửi 6 tiêu đề mới nhất và
ưu tiên bản dịch tiêu đề để giảm dữ liệu trùng lặp. Chỉ báo, lịch sự kiện và bản
đánh giá tin tức tổng hợp vẫn được gửi. Với DeepSeek-R1, hướng dẫn nằm trong user prompt
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
Xu hướng dùng H1 đã kết thúc; khi có OHLC M15 hợp lệ, các bộ lọc RSI,
Stochastic, Bollinger và khoảng cách SMA20 cho điểm vào dùng chỉ báo M15.

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

Ngoại lệ cho **vị trí chờ vào**: nếu bộ máy M15 đã xác nhận sweep + pinbar
cùng hướng lệnh (`blocked: false` và đúng `pattern`/`action`), vùng sweep được
chấp nhận thay cho yêu cầu gần SMA20 hoặc vùng retest. Không áp dụng ngoại lệ
cho mẫu đang chờ, sai hướng hay thiếu OHLC. Các khóa RSI (kể cả vùng reset),
Stochastic, Bollinger, cách SMA20 hơn 2 ATR, vùng cản và phá S1/R1 chưa retest
vẫn giữ nguyên, cùng các kiểm tra H1, tin tức và SL/TP. Đây là nới một điều kiện
vị trí, chưa phải triển khai thêm chiến lược hay kết quả backtest.

Nếu giá đã thủng S1 hoặc vượt R1, cần quan sát lần lượt phá mức → quay lại trong
±0,25 ATR → tiếp diễn qua mức hơn 0,25 ATR. Khi OHLC sẵn sàng, dùng chuỗi giá
đóng M15 cùng nguồn trong 90 phút; không suy ra retest chỉ từ High/Low. Thiếu chuỗi
hoặc chuỗi bắt đầu sau lúc phá mức thì chưa xác nhận được retest. Một lần phá
mới sau khi giá quay lại phía đối diện làm mất xác nhận cũ. Đây là xác nhận trên
mẫu giá đóng cửa, không phải xác nhận đường đi của từng tick trong nến.

Khi chờ, chỉ hiện kịch bản cùng xu hướng: Sell Limit phía trên giá hiện tại hoặc
Buy Limit phía dưới, quanh SMA20 trong 0,5 ATR. SL/TP tham chiếu tính lại từ vùng
chờ; không tạo kịch bản bắt đáy ngược xu hướng. Các kịch bản chưa phải lệnh đã đặt
và vẫn yêu cầu kiểm tra lại điều kiện, xác nhận nến M15 trước khi sử dụng. Dữ liệu
khởi tạo không xuất vùng đặt lệnh chờ.

Quy ước 0,25 / 0,5 / 2 ATR cụ thể hóa các khái niệm “sát vùng”, “hồi về” và “quá
xa”; đây là tham số chiến lược, chưa phải kết quả tối ưu hoặc backtest. Khi nguồn OHLC sẵn sàng, ATR H1 và M15 đều là trung bình 14
True Range từ High/Low/Close; bộ lọc điểm vào dùng sàn 0,5 USD. Mọi vùng giá tính từ dữ liệu hiện tại.

Quá mua/quá bán không bảo đảm đảo chiều; mục tiêu của bộ lọc là tránh vào đuổi,
không chứng minh một lệnh chắc chắn có lợi nhuận. Tham khảo
[Fidelity về RSI trong xu hướng mạnh](https://www.fidelity.com/learning-center/trading-investing/technical-analysis/technical-indicator-guide/RSI).

## Luồng OHLC M15/H1 từ Gold API

Nguồn: [Gold API](https://gold-api.com/docs), endpoint `/ohlc/XAU`.
Mỗi request trả một nến cho khoảng thời gian được yêu cầu. Gói miễn phí hiện
cho 10 request lịch sử/OHLC mỗi giờ và cần API key; xem
[tài liệu endpoint](https://gold-api.com/llms.txt) và [hạn mức](https://gold-api.com/pricing).
Ứng dụng không tự đăng ký tài khoản, mua gói hoặc đọc key từ chat.

Thiết lập `GOLD_API_KEY` trong `env.sh` trên VPS, rồi build/deploy mã mới.
Compose đã truyền biến này vào API; `deploy.sh` chạy migration tạo hai bảng
`market_candles` và `ohlc_requests` trước khi khởi động container.
Nếu chạy local, đặt biến trong môi trường shell và chạy `mix ecto.migrate`.
Không đưa key vào Git. Kiểm tra trạng thái mà không in key:

```bash
docker exec xauusd-api-1 /app/bin/gold_backend rpc \
  'IO.inspect(GoldBackend.Services.GoldOhlc.configured?())'
```

`true` chỉ xác nhận có cấu hình, chưa chứng minh key được nhà cung cấp chấp nhận.

Luồng chạy tự động:

1. `InsightCache` kích hoạt **35 giây sau** mốc :00/:15/:30/:45 để nguồn có thời
   gian cập nhật nến đã đóng. Khi khởi động, chờ mốc kế tiếp. Không chạy chồng tác vụ.
2. `OhlcSync` kiểm tra `/price/XAU`: đúng XAU/USD và timestamp của nguồn không
   cũ hơn 120 giây so với giờ máy chủ. Cho phép timestamp nguồn đi trước máy chủ
   tối đa 60 giây để chịu được độ lệch nhỏ (ví dụ VPS chậm 36 giây). Đồng hồ được
   đọc sau khi nhận phản hồi HTTP. Timestamp đi trước hơn 60 giây trả `clock_skew`,
   báo giá quá cũ trả `stale_quote`, sai cấu trúc/giá/timestamp trả `invalid_quote`;
   cả ba trường hợp đều chặn gọi OHLC và hiển thị lý do riêng.
   Đây là dung sai kiểm tra, không sửa đồng hồ VPS hay thay đổi lịch đóng nến M15/H1;
   VPS vẫn cần đồng bộ NTP để lịch phân tích đúng giờ. Báo giá cũ/nguồn lỗi không
   được coi là thị trường đang hoạt động.
3. Lấy nến M15 vừa đóng, sau đó bổ sung một nến H1 còn thiếu. Khi đã có 50 H1 và
   giờ H1 mới nhất, dung lượng còn lại dùng để sửa khoảng trống M15 trong 50 nến gần nhất.
4. `GoldOhlc` gửi API key qua header, dùng timestamp UTC, kiểm tra biên thời gian
   phản hồi, giá dương và quan hệ High/Low/Open/Close. Khoảng truy vấn kết thúc
   ở giây cuối của nến; không lấy dữ liệu từ nến tiếp theo. Không dựng râu nến từ
   báo giá 3 phút, seed hoặc synthetic.
5. `CandleStore` upsert theo nguồn + khung thời gian + giờ mở nến. Lịch sử và bộ
   đếm lượt gọi lưu PostgreSQL, không mất khi ứng dụng khởi động lại.
6. Controller đọc OHLC đã lưu để tính H1 và M15 cùng nguồn. Giá vào tham chiếu
   là giá đóng M15; giao diện ghi rõ đây là giá đóng nến, không phải báo giá khớp lệnh.

Tối đa hai request OHLC mỗi chu kỳ và **8 request trong một giờ trượt** cho ứng
dụng. Dành chỗ cho lần gọi thất bại và tránh sát trần gói miễn phí; các ứng dụng
khác dùng chung key vẫn có thể làm hết quota. Mỗi lượt được đặt chỗ trong DB
trước khi gọi HTTP, có khóa transaction cho nhiều instance. HTTP 401/403/429
làm tạm dừng gọi OHLC một giờ. Lỗi không được lưu thành nến; khoảng lịch sử trả
OHLC không hợp lệ được bỏ qua sáu giờ để không kẹt mãi ở một giờ nghỉ thị trường.

**Khởi tạo cần thời gian:** từ DB trống, mỗi chu kỳ lấy tối đa một M15 và một H1.
Trong điều kiện nguồn liên tục có dữ liệu, cần khoảng **50 chu kỳ ≈ 12,5 giờ**
để có 50 nến mỗi khung. Lỗi mạng, quota và giờ thị trường đóng cửa làm lâu hơn.
Không cam kết thời điểm có lệnh. Giao diện hiển thị số M15/H1 đã lưu và lỗi nguồn.
M15 yêu cầu tối thiểu 30 nến liên tục, mới nhất đúng mốc phân tích; khoảng nghỉ/gap
trong cửa sổ đó giữ `wait` cho đến khi có chuỗi hợp lệ. H1 cần tối thiểu 30 nến và giờ
đã đóng mới nhất. Dữ liệu cũ chỉ phục vụ hiển thị khi nguồn không sẵn sàng.

Kết quả AI sang chu kỳ sau bị loại; snapshot hết hạn chuyển `wait`, Telegram
kiểm tra hạn trước khi gửi. Đồng hồ trên UI đếm đến mốc nến tiếp theo, sau đó
chờ lấy dữ liệu và phân tích. Nến đang chạy bị bỏ qua kể cả trong 3–5 phút cuối.
OHLC đầy đủ cải thiện dữ liệu đầu vào, không chứng minh chiến lược có lợi nhuận.

Các kiểm thử parser và đồng bộ dùng HTTP giả lập; test database nằm ở
`test/gold_backend/candle_store_test.exs` và cần PostgreSQL test qua `mix test`.
Kết nối OHLC thật chỉ có thể xác minh sau khi đặt key hợp lệ.

`M15Signal` kiểm tra chiến lược quét thanh khoản đối xứng BUY/SELL:

- H1 xác nhận hướng bằng giá so với SMA20 và dấu MACD.
- Bốn nến trước tạo vùng có độ rộng không quá 2 ATR M15.
- Nến cuối phá đỉnh/đáy vùng rồi đóng lại trong vùng. Pinbar có thân ≤30%,
  râu quét ≥60% biên độ và giá đóng trong 40% phía đối diện râu.
- Phân kỳ RSI dùng hai đỉnh/đáy cục bộ được xác nhận bởi hai nến mỗi phía;
  điểm thứ hai nằm trong tám nến gần nhất. Phân kỳ ngược H1 khóa điểm vào.
- SL ngoài râu nến 1,50 USD; TP ở 2R trước spread. SL quá 5 ATR, SL sai phía
  hoặc mức giá không dương bị chặn. Các bộ lọc chống vào đuổi và tin tức vẫn áp dụng.

Đây là nhánh sweep + pinbar; nến Marubozu hoặc breakout đơn lẻ không đủ để
mở tín hiệu. Các ngưỡng là quy ước triển khai, chưa qua backtest; không cam kết
đảo chiều, khớp lệnh hay lợi nhuận. Hệ thống không tự đặt lệnh ở broker.

## Cấu hình trên VPS

Trong `/home/deploy_user/xauusd/env.sh`, giữ nguyên dòng `OLLAMA_MODEL` và thêm
hoặc sửa các biến sau (đơn vị timeout là mili giây):

```bash
export OLLAMA_TIMEOUT_MS=300000
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
ví dụ 90000. Tăng timeout làm kết quả đến muộn hơn; nếu một lượt vượt mốc M15
kế tiếp, hệ thống bỏ qua lượt kích hoạt khi còn bận và loại kết quả đã hết chu kỳ.

Để chạy thử với dữ liệu hiện có mà không cập nhật snapshot dashboard hay gửi
Telegram (tránh chạy nhiều lần đồng thời):

```bash
docker exec xauusd-api-1 /app/bin/gold_backend rpc \
  'result = with {:ok, context} <- GoldBackendWeb.TradingController.build_context(translate_timeout: 8000), do: GoldBackend.Services.AiDecision.analyze(context); IO.inspect(result, limit: :infinity)'
```

Lệnh này vẫn thực hiện các bước chuẩn bị dữ liệu/dịch tiêu đề thường lệ. Kết quả
thành công là `{:ok, action, "nhận định tiếng Việt..."}`; `action` có thể là
`:buy`, `:sell` hoặc `:wait`. `Tin tức xung đột` chỉ là nhãn phân loại tin tức, không phải lỗi
tiếng Việt. Telegram chỉ gửi Buy/Sell cuối cùng, không gửi khi chờ hoặc AI lỗi.
