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

Snapshot kiểm tra lại bình luận trước khi hiển thị. Khi không hợp lệ,
`ai_action: null` kèm `ai_error`; quyết định theo rule không bị AI thay đổi.
Telegram kiểm tra bình luận trước khi sử dụng; nếu chưa có bình luận hợp lệ,
thông báo dùng lý do từ rule. Không thay model hay temperature.

## Bộ tín hiệu hiện hành: zoi-v5-setup-policy

V5 áp dụng phân loại của bản thử nghiệm v2 trong thiết kế; dùng version mới để
không gộp thống kê/lịch sử với v4. Không cần thêm migration cho thay đổi này.

- `checks` có `required`, `scope` (`required`, `setup`, `advisory`) và status
  `pass/blocked/unknown/warning`. Chỉ các check bắt buộc chưa đạt ngăn phát tín hiệu.
  H1 định hướng và khung ưu tiên 14:00–22:00 là khuyến nghị. Thiếu H1 vẫn là lỗi
  dữ liệu bắt buộc; `data_status` tách khỏi `side` trung tính. Cooldown đổi hướng
  không được dùng như một thị trường trung tính để lách kiểm tra.
- Lệnh hồi vẫn cần H1 cùng hướng. H1 trung tính đủ dữ liệu được xét breakout–retest
  BUY/SELL; không mở nhánh giao dịch ngược H1. Nhánh setup được lưu vào snapshot.
- Thêm vùng breakout từ high/low của 20 nến M15 trước nến breakout. Breakout đóng
  vượt mức + đệm 0,10 ATR; vùng retest hình thành lúc breakout đóng. ATR dựng vùng
  chỉ dùng nến tới breakout, không dùng nến retest. Nến kế tiếp phải chạm lại vùng,
  giữ mép đối diện và đóng cùng hướng bên ngoài vùng. Không phát ngay khi chỉ breakout.
- TP được chọn ở cản gần nhất trong các vùng H1/ngày trước và swing M15 (hai nến
  xác nhận mỗi phía), đã biết trước nến trigger. Không bỏ qua cản gần để chọn TP xa.
  Gộp `barrier_room` vào `reward_risk`: phải đủ 1,5R sau chi phí tới cả TP và cản đầu.
- Giữ 30 phút từ xác nhận, lệch bất lợi ≤0,30 ATR₀, SL ≤5 ATR₀, giá mới ≤120 giây.
  Giá đi trước máy chủ quá 5 giây bị loại thống nhất ở adapter và bộ rule.
- Với retest, chạm SL vô hiệu ngay; râu xuyên mép vùng nhưng chưa chạm SL không tự
  vô hiệu. Nến M15 đóng vượt điểm vô hiệu đã lưu sẽ hủy setup. Điểm vô hiệu và
  quy tắc này hiện trong kế hoạch; nhánh hồi giữ kiểm tra mép vùng tại báo giá.
- Cache lịch tin được tải lại sau 5 phút, chỉ dự phòng lỗi tới tối đa 15 phút từ
  lần tải thành công. Không gia hạn khi dùng lại; phải bao phủ cửa sổ yêu cầu trong
  tuần dữ liệu. Hết cache, qua tuần hoặc thiếu phạm vi thì chưa xác minh. API/FE
  tự dừng khi cache hết hiệu lực. Cửa sổ tin vẫn 15 phút trước–30 phút sau.
- Đồng bộ OHLC lịch sử không phụ thuộc endpoint giá trực tiếp hoạt động; vẫn giữ
  hạn mức 8 lượt/giờ. Tín hiệu mới vẫn bắt buộc báo giá hợp lệ. Lượt đánh giá chạy
  mỗi phút, không thay timestamp nguồn bằng thời điểm HTTP để làm giá trông mới.
- `MarketSchedule` chỉ bỏ qua nến thiếu nếu **toàn bộ khoảng nến** thuộc khoảng
  nghỉ đã khai báo trong `:market_closures`, là danh sách `%{from: DateTime, until:
  DateTime}` UTC. Khoảng nghỉ cũng chặn phát tín hiệu và không bị gọi OHLC backfill.
  Mặc định chưa có lịch nghỉ xác minh từ nguồn: không tự suy diễn gap cuối tuần,
  ngày lễ hoặc giờ broker. Ngoài khoảng nghỉ khai báo, hoạt động nguồn được kiểm
  tra bằng báo giá mới và nến mới; đây không phải trạng thái sàn/broker được xác nhận.
  Các kỳ nghỉ có DST phải được chuyển đúng sang UTC khi cấu hình.
- Giờ Telegram độc lập qua `TELEGRAM_NOTIFY_HOURS` (mặc định `14-22`, giờ Việt Nam;
  `all` hoặc khoảng qua nửa đêm như `22-7`). Ngoài giờ vẫn lưu tín hiệu, không gửi bù
  tín hiệu cũ sau đó. Không thay số lượng lệnh/vị thế hay gắn tài khoản broker.
- UI dùng tick / X / đồng hồ / tam giác cảnh báo cùng nhãn chữ; các khuyến nghị
  không tính vào số chặn hoặc “chặn duy nhất”. Bỏ bộ lọc và impact-label của bài viết,
  giữ bảo vệ lịch sự kiện riêng. Hết dữ liệu, các check không giữ tick xanh cũ.

Theo [tài liệu Gold API](https://gold-api.com/llms.txt), `/price/XAU` có timestamp
nguồn và `/ohlc/XAU` là endpoint riêng. Không dùng tần suất lấy dữ liệu để suy diễn
rằng timestamp upstream mới hay thị trường đang mở. Bộ này vẫn cần mô phỏng đánh
giá, chưa có bằng chứng tối ưu lợi nhuận.

## Nền tảng v4: zoi-v4-confluence

V4 mở rộng cách tìm setup, không cộng mọi chỉ báo thành điều kiện chặn:

- Duyệt tất cả vùng chạm có xác nhận. Ưu tiên setup đạt cấu trúc/R:R tại giá xác nhận,
  rồi setup có khoảng entry khả thi, sau đó mới tới setup đang thiếu điều kiện.
  Trong cùng nhóm, ưu tiên R:R sau spread giả định, số nhóm bằng chứng hỗ trợ, rồi ID
  để kết quả không phụ thuộc thứ tự vùng. Đây không phải tối ưu lợi nhuận đã kiểm chứng.
- Bốn xác nhận thay thế nhau: pinbar, engulfing, sweep–reclaim, phá vỡ–retest.
  Retest yêu cầu thân nến trước đóng qua mép ngoài vùng đã tồn tại trước nó;
  nến sau chạm lại vùng, giữ mép vô hiệu và đóng cùng hướng bên ngoài vùng.
  Vùng kháng cự chỉ đổi thành vùng BUY qua retest này; hỗ trợ đổi thành SELL đối xứng.
- ATR của OHLC dùng Wilder RMA14, khởi tạo bằng trung bình 14 true range đầu;
  nến đầu dùng high−low. ATR của nhánh quote cũ vẫn chỉ là xấp xỉ.
- EMA20/25/30/35/40/45/50/55 là **một nhóm** bằng chứng, cần 55 nến; seed SMA
  của N nến đầu. Không thêm tám phiếu đồng thuận hay suy diễn xác suất thắng.
- Cấu trúc H1 dùng pivot hai nến mỗi phía, ghi riêng `pivot_at`/`confirmed_at`,
  HH/HL/LH/LL (bằng nhau là EH/EL). Phá bằng giá đóng tạo Break đầu tiên, BoS cùng
  hướng hoặc CHoCH ngược hướng; mỗi mức chỉ phát một lần cho tới mức pivot khác.
- Fibonacci 0,236/0,382/0,5/0,618/0,786 từ cặp đỉnh/đáy gần nhất đã xác nhận,
  lưu cả hai điểm neo. Trùng vùng entry là bằng chứng bổ sung, không phủ quyết.
- AOI từ cực trị thân 50 nến H1 ± ATR14, chỉ thêm **vùng entry chờ phản ứng**.
  Không biến AOI/Fibonacci/EMA ribbon thành hàng loạt vùng cản TP mới.
  Đỉnh/đáy rolling 4/24 giờ chỉ hiển thị khi đủ cửa sổ nến đã đóng liên tục.
- Bối cảnh được tính trước nến trigger và lưu cùng setup. Không lấy pivot tương lai,
  không giả lập volume thiếu, không cam kết khớp chỉ báo TradingView/Mxwll.
  Các chỉ báo hỗ trợ không thay thế hướng H1 hay các kiểm tra bắt buộc hiện hành.
- Phần R:R thêm kịch bản chi phí bằng hai lần spread để xem độ nhạy, không thêm
  ngưỡng chặn. Chi phí này không phải spread broker, phí hay trượt giá quan sát được.

V3 và kết quả mô phỏng cũ giữ nguyên; v4 có ID/version riêng để đối chiếu về sau.
Giao diện bỏ mục “Phạm vi và nguồn dữ liệu” và cảnh báo headline chung; lịch tin
USD High và kiểm tra độ mới dữ liệu vẫn hoạt động. Chi phí giả định vẫn ghi bên R:R.

Kế hoạch công khai có hướng, bằng chứng H1/M15, vùng entry, điều kiện xác nhận,
SL và lý do vô hiệu, TP kèm vùng cản, R:R, nguồn giá, chi phí và thời hạn.
Vùng theo dõi trước xác nhận được phân biệt với khoảng entry đủ điều kiện sau xác nhận.
Khoảng entry sau xác nhận là giao của các điều kiện cấu trúc, độ lệch 0,30 ATR,
SL ≤ 5 ATR và R:R sau chi phí ≥ 1,5; hai biên làm tròn vào trong tới 0,01 USD.
RSI/Stochastic vẫn không có quyền phủ quyết độc lập. Lý do H1 nêu rõ giá/SMA20,
MACD, ADX và độ dốc, hoặc lý do chưa có hướng.

TP dùng mép gần vùng cản H1 đã biết trước trigger, không thay bằng một mục tiêu 2R
khi thiếu cản. Khi chưa xác định TP, trạng thái là chờ mục tiêu, chưa phát tín hiệu.
Chi phí giả định được ghi ngay tại phần R:R của kế hoạch; số spread giả định
vẫn không xuất hiện như một báo giá trực tiếp trong phần tổng quan thị trường.

### Lịch sử mô phỏng chạm giá

`GET /api/trading/signals` trả 50 tín hiệu mới nhất, kế hoạch nguyên bản và kết quả
được lưu trong `signal_outcomes`. Tín hiệu v2 vẫn được giữ nhưng không được tự
backfill thành mô phỏng v3. Cửa sổ entry kết thúc cùng thời hạn setup; cửa sổ
theo dõi TP/SL cố định là **hai giờ từ lúc phát**. Mô hình `m15-touch-v1`:

- Chỉ dùng nến Gold API M15 đã đóng và trọn vẹn sau lúc phát. Bỏ qua phần nến
  chứa thời điểm phát và phần nến cuối vượt cửa sổ; giao diện ghi rõ giới hạn này.
- Entry được ghi nhận khi phạm vi nến chạm vùng entry. Giá mô phỏng là Open nếu
  Open nằm trong vùng, hoặc mép đầu tiên của vùng từ phía Open. Đây không phải fill.
- Sau entry, ghi TP trước, SL trước hoặc chưa chạm cả hai trong thời hạn. Không tính
  P&L, tỷ lệ thắng giao dịch thực, phí thực hay lợi nhuận của tài khoản.
- Cùng nến chạm cả hai mức thoát, hoặc entry nội nến và mức thoát cùng được chạm,
  ghi không xác định thứ tự. Không tự chọn TP để làm đẹp kết quả.
- Gap mở cửa vượt SL trước entry không được coi là khớp. Hủy giữa nến cần chờ
  nến đóng; nếu không biết entry trước hay sau hủy thì ghi không xác định.
- Thiếu, trùng hoặc nến không hợp lệ: chưa kết luận; thử lại trong bảy ngày.
  Kết quả đã kết thúc được giữ cố định. Việc restart không xóa kế hoạch hoặc kết quả.
- Hiệu lực active/expired/invalidated tách biệt với kết quả mô phỏng; hết hạn entry
  không kết thúc sớm việc quan sát một entry đã chạm trong mô hình.

Chạy migration `20261024000200_create_signal_outcomes` cùng các migration còn lại
trước khi khởi động mã mới. Kiểm thử: `signal_simulator_test`, `signal_history_test`,
`decision_plan_test` và các kiểm thử pipeline/expiry. Đây là đánh giá chạm giá
theo quy tắc đã công bố, chưa phải backtest thực thi broker.

### Các kiểm soát chung của luồng tín hiệu

Dashboard chạy `BiasEngine → SetupLifecycle/SetupRegistry → StrategyPlan → DecisionJournal`.
`EntryRules` và `M15Signal` bên dưới là nhánh cũ, không quyết định tín hiệu của luồng này.
Phiên bản mới là cấu hình thử nghiệm, chưa có kết quả backtest hoặc chứng minh lợi nhuận.

- Chỉ phát tín hiệu; không đặt lệnh, theo dõi vị thế hay suy diễn giao dịch đã khớp.
  Không áp dụng quota ba lệnh, một vị thế hoặc ngân sách lỗ khi chưa có dữ liệu tài khoản.
- RSI/Stochastic cực đoan là cảnh báo; H1, vùng giá và xác nhận M15 vẫn bắt buộc.
- Lệch bất lợi tối đa `0,30 × ATR M15` lúc xác nhận, không có trần 1 USD.
  BUY đo `max(0, giá hiện tại − giá tham chiếu)`, SELL đo ngược lại. Cả hai là giá
  tham chiếu Gold API, không trộn với bid/ask broker. Giá tốt hơn vẫn phải giữ cấu trúc.
- Giữ SL ≤ 5 ATR và R:R sau chi phí ước tính ≥ 1,5. Tính lại ở báo giá cuối cùng
  trước khi phát tín hiệu, không kéo SL/TP để làm đẹp R:R. Spread giả định được giữ
  trong phép tính và ghi bên R:R, không hiện như spread trực tiếp; `execution_ready` luôn false ở chế độ này.
- Vùng cản dùng đỉnh/đáy ngày trước đầy đủ và swing H1 có hai nến xác nhận mỗi phía,
  đã biết trước nến trigger. TP đặt tại mép gần của vùng cản; đánh giá riêng
  khoảng trống tới cản. Phá vỡ chỉ được xét sau retest như quy tắc v4 ở trên.
- Mã setup gồm phiên bản, hướng, định danh vùng và thời điểm xác nhận. Lưu cố định
  giá tham chiếu, ATR, vùng, SL/TP ở lần quan sát đầu. Setup hết hạn sau hai nến M15,
  hoặc vô hiệu khi phá cấu trúc, chạm TP, đổi hướng H1 hay đi qua cửa sổ tin đỏ.
- Giữ cửa sổ tin USD High: 15 phút trước / 30 phút sau. Sau tin cần xác nhận mới.
  Lịch tải lỗi là `unknown`, không được xem là không có sự kiện.
- Mỗi phút kiểm tra lại dữ liệu và entry; không nới ngưỡng báo giá 120 giây.
  API và trình duyệt tự chuyển sang chờ khi giá quá hạn hoặc sang nến M15 mới.
  Lỗi lấy giá vẫn cho phép cập nhật bảng điều kiện theo dữ liệu đã lưu.
- Bỏ quota một phiếu mỗi phiên. `strategy_signals.setup_id` chống phát lại cùng
  setup, bao gồm qua restart; nhật ký vô hiệu ngăn setup cũ sống lại khi giá hồi.
  AI được gọi một lần lúc phát tín hiệu mới và chỉ bổ sung bình luận.

Giao diện tách hướng H1, trạng thái setup và thực thi; có trạng thái chờ xác nhận,
chờ hồi, đủ điều kiện phát tín hiệu, hết hạn, vô hiệu, tạm dừng và cửa sổ tin.
Bảng thống kê bảy ngày đếm từng lần đánh giá theo phút: đạt, chặn, chưa xác định,
và chặn duy nhất khi mọi điều kiện còn lại đều đạt. Có thể đọc cùng số liệu bằng
`mix gold.decisions`. Không coi số tín hiệu hoặc số lần chặn là số lệnh khớp hay lợi nhuận.

Chạy migration trước khi khởi động bản mới: `mix ecto.migrate` (hoặc migration
của release trong quy trình deploy). Các bảng v1 được giữ nguyên làm dữ liệu đối chiếu;
v2 thêm `strategy_setups`, `strategy_signals`, `strategy_evaluations`, `strategy_invalidations`.
Kiểm tra bằng `mix test`, và `npm test`, `npm run build` trong frontend. Chưa triển khai
broker, backtest khớp lệnh, spread lịch sử, trượt giá, ngân sách tài khoản hay quản lý SL sau khớp.

## Nhánh cũ: quy tắc điểm vào EntryRules

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
tiếng Việt. Telegram chỉ gửi tín hiệu Buy/Sell mới theo rule, không gửi khi chờ.
