# Quy tắc hành vi — KHÔNG được vi phạm

Những quy tắc này quan trọng hơn tính nhất quán hay thẩm mỹ. Chúng đến từ brief gốc
(`design/redesign-brief.md`, §3) và có lý do tâm lý, không phải lý do thiết kế.

1. Bốn trạng thái, mỗi màu một nghĩa duy nhất: **Held** (chuỗi còn sống) · **Urgent**
   (sắp hết chỗ, chưa mất gì) · **Failed** (bỏ lỡ, hoặc đang nợ tiền) · **Neutral**
   (mọi thứ còn lại, kể cả việc chưa làm).
2. Urgent phải phân biệt được với Failed *trước khi đọc chữ*. Trong bản này: khác hue
   **và** khác hình dáng — nhãn urgent là viền rỗng bo 6px, mọi nhãn khác là pill đầy 999px.
3. **Không bao giờ tô màu hai nút tự khai báo buổi sáng.** `It held` và `I slipped` phải
   giống nhau hoàn toàn: cùng neutral, không mặc định chọn sẵn, không bước xác nhận.
4. Nút phán quyết của referee thì ĐƯỢC tô màu — anh ta phán xử người khác, không phải tự thú.
5. Không màn hình nào đỏ toàn bộ, kể cả Ledger. Hàng `Owed` giữ neutral; chỉ `Waived` /
   `Collected` được tô tint. Chỉ duy nhất khối số nợ là vùng tint lớn.
6. Không bao giờ tô màu một commitment chỉ vì nó *chưa* xảy ra.
7. Đỏ = bỏ lỡ hoặc đang nợ. Không dùng đỏ để nhấn mạnh, gây chú ý hay báo gấp.
8. Con số nợ là thứ to nhất và đậm màu nhất trong sản phẩm. Cố ý như vậy — đừng làm nhẹ đi.
9. Nhãn trạng thái không bao giờ bấm được; không control nào có hình dáng giống nhãn trạng thái.
10. Không có gì phá hoại xảy ra trong một cú tap (xoá commitment phải xác nhận), **nhưng**
    khai báo `I slipped` chỉ một tap — trung thực không phải phá hoại.
11. Tối đa một primary action mỗi màn hình.
12. Màu không bao giờ là thứ duy nhất mang trạng thái: mọi nhãn đều có chữ hoặc số
    (`12`, `1/3 · 3 days`, `Owed`, `Waived`).

## Chuyển động
Gần như không có. Timer cập nhật bằng text, quota track là fill tĩnh. Dưới Reduce Motion
không có gì thay đổi vì vốn không có animation nào.

## Accessibility
- Contrast: tất cả cặp màu đã đo, in trong `design/Style page.dc.html` và `tokens.css`.
- Mọi control tối thiểu 44×44pt.
- Type ramp phải chịu được text-size của người dùng: không row cố định chiều cao, kể cả
  hai con số lớn. Dùng `min-height`, không `height`.
- Thứ tự đọc trên Today: các hàng commitment được announce **trước** con số nợ, dù con số
  được vẽ trước. Người sáng có thể bỏ qua con số, người dùng screen reader thì không.
