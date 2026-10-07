# SmartOrder Engine Bot

**Version:** 3.60
**Platform:** MetaTrader 5 (MT5)
**Asset:** XAUUSD (Gold)

## Mô tả
Đây là một Expert Advisor (EA) trade vàng chuyên nghiệp, sử dụng cấu trúc giao dịch: Adaptive regime + event-score engine. Bot xác định xu hướng và vào lệnh (Breakout hoặc Trend continuation) bằng hệ thống tính điểm động (Dynamic BUY/SELL score).

## Tính năng chính
- Nhận diện Regime (Trend, Range, Breakout, Compression, Transition).
- Quản lý 2 lệnh (Leg 1 chốt lời ở TP1, Leg 2 chạy theo trend - Runner).
- Đóng lệnh thông minh bằng Event Exit Engine.
- DCA/Pyramiding chiều dương cho lệnh Runner.

## Ghi chú Backtest (Các lỗi đang gặp phải)
Qua quá trình test, bot đang gặp phải một số lỗi logic cần được tối ưu:
1. **Dời SL hòa vốn (Break-even) quá vội**: Dẫn đến việc lệnh dễ bị cắn SL hòa vốn do nhiễu sóng (noise) hoặc spread trước khi giá thực sự chạy.
2. **Over-entry (Vào quá nhiều lệnh) khi ngược sóng đa khung thời gian**:
   - Khi khung lớn H1, H4 đang là xu hướng Giảm (Bear).
   - Nhưng khung nhỏ M15 lại xuất hiện tín hiệu Tăng (Bull).
   - Khi giá pullback/retest quá nhiều lần, bot dễ bị nhiễu tín hiệu và vào quá nhiều lệnh ngược với xu hướng chính.

## Hướng phát triển
- Tối ưu lại logic dời Stoploss (chờ giá đi xa hơn, ví dụ 1.5R hoặc 2R mới dời BE).
- Thêm bộ lọc (Filter) chặt chẽ hơn để giới hạn số lệnh vào khi tín hiệu M15 ngược với cấu trúc của H1/H4.
