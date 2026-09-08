# Handoff: todoapp — redesign giao diện (doer PWA + referee web)

## Tổng quan
Bộ này là bản thiết kế hi-fi cho hai surface của cùng một sản phẩm: app điện thoại (PWA)
của người cam kết — gọi là *doer* — và web app của người bạn giữ vai trò *referee*.
Sản phẩm là một **sổ ghi chép**, không phải app tạo động lực: không confetti, không huy
chương, không progress ring, không câu chữ cổ vũ.

Toàn bộ nội dung, tên màn hình và câu chữ interface trong file thiết kế là **verbatim từ
brief gốc** (`design/redesign-brief.md`). Không viết lại copy khi implement.

## Về các file thiết kế
Ba file `.dc.html` trong `design/` là **bản tham chiếu thiết kế viết bằng HTML** — không
phải production code để copy vào app. Việc cần làm là **dựng lại các thiết kế này trong
codebase React + Next.js + Tailwind của bạn**, dùng đúng pattern và component đã có.
Mở trực tiếp trong browser; mỗi trang có nút **Light / dark** ở header để đổi palette.

- `design/Style page.dc.html` — palette với 4 nghĩa trạng thái và contrast ratio đã đo,
  type ramp, spacing, shape, toàn bộ component inventory, wordmark, app icon, và 10 dòng
  rationale cho những chỗ đổi khác so với hệ thống cũ.
- `design/Doer surface.dc.html` — 16 frame ở 390×844: sign in (default/error), Morning
  Declaration, Today (normal / everything held / day failed / empty), Chains detail, Focus
  Session, Appeal, Ledger, Task setup, Week close, Monthly report, Settings, Silence
  intervention, và 5 template notification trên lock screen.
- `design/Referee surface.dc.html` — 6 frame ở 1280×900: sign in / accept invite, Referee
  home (empty / có việc / doer đã im lặng), Appeal detail, Day lookup.
- `design/redesign-brief.md` — brief gốc, là nguồn chân lý cho copy và hành vi.
- `RULES.md` — 12 quy tắc bắt buộc. **Đọc trước khi code.**
- `tokens.css` — design token cho light + dark, kèm contrast ratio.
- `tailwind.config.js` — mapping token sang Tailwind theme.
- `design/assets/logo.png` — logo / app icon do bạn cung cấp.

## Fidelity
**High-fidelity.** Màu, type, spacing, radius là giá trị cuối. Dựng lại đúng pixel bằng
component library của bạn; đừng thay bằng style sẵn có nếu nó lệch khỏi token.

## Layout chung cho cả hai surface
Một cột duy nhất, tối đa **544px (34rem)**, canh giữa ở mọi bề rộng — kể cả trên desktop
1280px của referee. Không màn hình nào có sidebar hay layout rộng hơn ở breakpoint lớn.
Đây là app điện thoại tình cờ mở được trên desktop.

## Type
| Vai trò | Font | Size | Weight |
| --- | --- | --- | --- |
| Figure (chỉ số nợ + timer) | Caprasimo | 34→44px, tracking −0.02em, tabular-nums | 400 |
| Screen title | Figtree | 17→21px, tracking −0.01em | 600 |
| Body | Figtree | 15→16px | 400 |
| Label | Figtree | 13→14px | 500 |
| Caption | Figtree | 11px | 400 |
| Collection message (1 chuỗi duy nhất) | Lora italic | 17→18px | 400 |

Caprasimo chỉ dùng cho: wordmark, con số nợ, timer. Không dùng cho title.
Lora chỉ dùng cho đúng một chuỗi: tin nhắn thu tiền của referee. Thêm serif thứ hai sẽ
xoá mất tín hiệu "câu này để người nói ra miệng".

## Component inventory (xem Style page để thấy từng cái)
Row (name + status label) · list frame · status label (4 biến thể) · debt figure block ·
primary action · cặp control tự khai báo neutral · destructive control (chỉ dùng cho xoá
commitment) · quiet navigation control · screen head 44px · card · tab bar · quota track ·
photo attachment + thumbnail · toggle row kèm câu giải thích hệ quả · collection card ·
empty state · inline error (`Failed.` + một câu lý do) · loading (`Working…`).

### Status label — spec chính xác
| Trạng thái | Nền | Chữ | Viền | Radius |
| --- | --- | --- | --- | --- |
| Held | `--held-tint` | `--held-ink` | 1px `--held-ink` | 999px |
| Urgent | trong suốt | `--urg-ink` | **1.5px** `--urg-ink` | **6px** |
| Failed | `--fail-tint` | `--fail-ink` | 1px `--fail-ink` | 999px |
| Neutral | `--neu-tint` | `--neu-ink` | 1px `--st` | 999px |

Padding 5px 11px, font-size 13px. Nhãn **không** có `onClick`, không `role="button"`,
không cursor pointer. Ngược lại, không control nào bo 999px.

## Màn hình
Từng frame trong hai file HTML đều có caption ghi rõ tên màn hình, state đang vẽ, và
những state còn lại khác chỗ nào. Đọc caption cùng với frame — đó là spec.

Điểm cần chú ý khi implement:
- **Today**: thứ tự vẽ là debt block → rows; thứ tự đọc (DOM/aria) là rows → debt block.
  Khối nợ render **không gì cả** khi không nợ. Row của commitment được máy kiểm tra không
  bấm được. Control của row tự khai báo chỉ hiện buổi sáng.
- **Morning Declaration**: chặn bằng cách không có gì khác để làm, không phải bằng cách
  giam thiết bị (không chặn back, không modal không đóng được). Không nhắc tiền khi hỏi.
- **Focus Session**: timer là figure thứ hai và cuối cùng dùng Caprasimo. Chạy tiếp khi
  máy khoá.
- **Appeal**: câu "on hold, not charged" là câu quan trọng nhất về mặt tin cậy trong sản
  phẩm — cho nó trọng lượng typographic thật. Tiền đang giữ là **urgent**, không phải failed.
- **Ledger**: đây là danh sách toàn thất bại, nhưng không được là màn hình đỏ nhất app.
- **Settings**: row "Home screen" quan trọng hơn mọi row khác — không install thì iOS
  không gửi push, không push thì không có sản phẩm.
- **Silence intervention**: thay thế toàn bộ nội dung, **gửi đúng một lần**, không có số nợ.
- **Notifications**: mọi body tự chứa ngày/giờ để phân biệt bản cũ còn nằm trên lock screen
  với bản mới. Tối đa một action mỗi notification.

## State cần quản lý
- `declarationsPending: Date[]` — khác rỗng thì app mở vào Morning Declaration.
- `commitments[]` với `{ id, name, kind: 'do'|'avoid'|'hours', money: boolean, checks[], chain, quota }`.
- `todayStatus` mỗi commitment: `held | missed | pending | claimed | not-yet`.
- `debtTotal` (VND) + `ledger[]` với outcome `Owed | Collected | Waived | Dropped | Expired`.
- `appeals[]` với `{ machineAccount, photos[], status: 'held'|'upheld'|'denied'|'dropped', closesAt }`.
- `focusSession: { commitmentId, startedAt, bankedToday } | null` — chỉ một session tại một thời điểm.
- `graceDaysRemaining`, `quietDays`, `installState`, `notificationPermission`, `refereePairing`.

## Assets
`design/assets/logo.png` — do bạn cung cấp, dùng làm logo và app icon (120/60/30pt).
Không có asset nào khác; các ô ảnh trong thiết kế là placeholder cho ảnh thật của người dùng.
Icon: bộ Lucide, stroke-width 2.75 nếu cần thêm icon.

## Fonts
Caprasimo, Figtree, Lora — Google Fonts. Trong Next.js dùng `next/font/google` để tránh
layout shift.
