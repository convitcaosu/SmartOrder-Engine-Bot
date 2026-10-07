# SmartOrder Engine Bot

**Version:** 3.60
**Platform:** MetaTrader 5 (MT5)
**Asset:** XAUUSD (Gold)

## Mô tả
Đây là một Expert Advisor (EA) trade vàng chuyên nghiệp, sử dụng cấu trúc giao dịch: Adaptive regime + event-score engine. Bot xác định xu hướng và vào lệnh (Breakout hoặc Trend continuation) bằng hệ thống tính điểm động (Dynamic BUY/SELL score).

## Tính năng chính & Điểm ưu việt (So với các Bot thông thường)
- **Nhận diện Regime (Môi trường giá):** Không giống như các bot thông thường chỉ dùng Moving Average hay RSI đơn giản, SmartOrder Engine nhận diện được các trạng thái của thị trường (Trend, Range, Breakout, Compression, Transition), từ đó áp dụng chiến thuật phù hợp nhất.
- **Hệ thống tính điểm động (Event-score engine):** Thay vì các tín hiệu cứng nhắc (ví dụ: giao cắt là vào lệnh), bot đánh giá đa yếu tố để đưa ra điểm số (Score) trước khi ra quyết định, giúp lọc bỏ các tín hiệu nhiễu.
- **Quản lý vốn linh hoạt (Chốt lời từng phần):** Bot sử dụng kỹ thuật quản lý 2 lệnh rất hiệu quả: 
  - **Leg 1:** Chốt lời sớm ở TP1 để bảo toàn vốn, đảm bảo tài khoản không bị lỗ ngược và giảm áp lực tâm lý.
  - **Leg 2 (Runner):** Lệnh nuôi dài hạn gồng lời theo xu hướng lớn, tối đa hoá lợi nhuận.
- **Đóng lệnh thông minh (Event Exit Engine):** Không phó mặc vào SL/TP cố định, bot có cơ chế thoát lệnh sớm dựa vào các sự kiện giá, hành vi nến đảo chiều hoặc động lượng suy yếu.
- **DCA/Pyramiding chiều dương:** Khác với các bot rủi ro cao thường xuyên gồng lỗ bằng cách nhồi lệnh (Martingale), bot này nhồi thêm lệnh thuận xu hướng (Pyramiding) khi đang có lợi nhuận, biến một con sóng nhỏ thành phần thưởng lớn mà vẫn kiểm soát tối đa rủi ro.

## Ghi chú Backtest (Các lỗi đang gặp phải)
Qua quá trình test, bot đang gặp phải một số lỗi logic cần được tối ưu:
1. **Dời SL hòa vốn (Break-even) quá vội**: Dẫn đến việc lệnh dễ bị cắn SL hòa vốn do nhiễu sóng (noise) hoặc spread trước khi giá thực sự chạy.
2. **Over-entry (Vào quá nhiều lệnh) khi ngược sóng đa khung thời gian**:
   - Khi khung lớn H1, H4 đang là xu hướng Giảm (Bear).
   - Nhưng khung nhỏ M15 lại xuất hiện tín hiệu Tăng (Bull).
   - Khi giá pullback/retest quá nhiều lần, bot dễ bị nhiễu tín hiệu và vào quá nhiều lệnh ngược với xu hướng chính.
## Kết quả Backtest
<img width="945" height="257" alt="image" src="https://github.com/user-attachments/assets/43d02ec9-f322-4e86-a0bd-d90caafa161f" />

## Kết quả Backtest
<img width="945" height="318" alt="image" src="https://github.com/user-attachments/assets/48ae9f54-30a9-4c55-af05-2611f071b468" />
<img width="945" height="315" alt="image" src="https://github.com/user-attachments/assets/79d853f9-8dc3-4eff-8bda-20c184ccb805" />
<img width="945" height="315" alt="image" src="https://github.com/user-attachments/assets/902fec1f-0b7a-4e99-abc2-f8999cffc467" />
<img width="945" height="321" alt="image" src="https://github.com/user-attachments/assets/3090ef27-d57e-47a1-aa93-b97eb7c382a3" />
<img width="945" height="310" alt="image" src="https://github.com/user-attachments/assets/8dde2282-9cc0-429f-806b-da859a863d62" />

**Tổng quan kết quả:**
- Tài khoản vẫn duy trì mức lợi nhuận dương tốt nhờ kỹ thuật quản lý rủi ro khắt khe.
- **Khả năng gồng lời xuất sắc:** Nhờ lệnh Leg 2 (Runner), bot đã bắt được các con sóng dài, lợi nhuận từ các lệnh này đủ lớn để gánh vác các lệnh SL/Hòa vốn.
- **Xác định xu hướng chuẩn xác:** Việc áp dụng cấu trúc Regime kết hợp Event-score chứng minh được hiệu quả cao, giúp bot vào lệnh có tỷ lệ Winrate tốt trong dài hạn.

## Hướng phát triển
- Tối ưu lại logic dời Stoploss (chờ giá đi xa hơn, ví dụ 1.5R hoặc 2R mới dời BE) để tránh dính SL vô duyên bởi nhiễu (noise) của thị trường Vàng.
- Thêm bộ lọc (Filter) chặt chẽ hơn để giới hạn số lệnh vào khi tín hiệu M15 ngược với cấu trúc của H1/H4 (Tránh đánh nhồi ngược sóng).
