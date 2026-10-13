# quick-install

Kho các script cài đặt nhanh. Mỗi script chạy bằng **1 dòng lệnh `curl`**, không cần clone repo, không cần sửa file hay nhớ tham số: script tự hỏi từng bước và tự kiểm chứng kết quả.

## Mục lục

- [Danh sách tool](#danh-sách-tool)
- [Cách chạy một script](#cách-chạy-một-script)
- [Chi tiết từng tool](#chi-tiết-từng-tool)
  - [ssh-tunnel](#ssh-tunnel)
- [An toàn khi chạy script từ internet](#an-toàn-khi-chạy-script-từ-internet)
- [Cấu trúc repo](#cấu-trúc-repo)
- [Thêm tool / script mới](#thêm-tool--script-mới)

---

## Danh sách tool

| Tool | Giải quyết việc gì | Script | Chạy ở đâu | Quyền | Hệ điều hành |
|---|---|---|---|---|---|
| [`ssh-tunnel`](ssh-tunnel/) | SSH vào máy không có IP public (sau NAT/CGNAT) từ bất kỳ đâu, qua 1 VPS trung gian | `vps_setup.sh` | VPS (IP public) | root | Linux |
| | | `local_setup.sh` | Máy đích sau NAT | user thường hoặc root | macOS, Linux, WSL |

> Thêm tool mới: xem [Thêm tool / script mới](#thêm-tool--script-mới).

---

## Cách chạy một script

Mẫu lệnh chung:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/nguyenhungbk96/quick-install/main/<tool>/<script>.sh)"
```

Cần quyền root thì thêm `sudo` phía trước `bash`:

```bash
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/nguyenhungbk96/quick-install/main/<tool>/<script>.sh)"
```

Ý nghĩa các cờ của `curl`: `-f` báo lỗi nếu HTTP lỗi (không chạy nhầm trang 404), `-s` im lặng, `-S` vẫn in lỗi, `-L` theo redirect.

### Vì sao dùng `bash -c "$(curl ...)"` mà không dùng `curl ... | bash`

Các script ở đây **hỏi tương tác** và đọc câu trả lời từ stdin. Với `curl ... | bash`, stdin của bash chính là nội dung script, nên mỗi câu hỏi sẽ đọc mất các dòng code phía sau và script hỏng hoặc chạy sai. Với `bash -c "$(curl ...)"`, script được truyền vào dưới dạng chuỗi nên stdin vẫn là bàn phím.

### Chạy bản cố định (không theo `main`)

`main` có thể thay đổi. Muốn chạy đúng một phiên bản đã kiểm tra, thay `main` trong URL bằng **tag** hoặc **mã commit**:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/nguyenhungbk96/quick-install/<tag-hoặc-commit>/<tool>/<script>.sh)"
```

### Tải về đọc trước rồi chạy

```bash
curl -fsSLO https://raw.githubusercontent.com/nguyenhungbk96/quick-install/main/<tool>/<script>.sh
less <script>.sh          # đọc nội dung
bash <script>.sh          # (hoặc sudo bash <script>.sh)
```

---

## Chi tiết từng tool

### ssh-tunnel

**Bài toán:** máy ở nhà, laptop qua WSL, máy sau router/CGNAT không có IP public nên không thể SSH vào từ ngoài. Giải pháp là dùng 1 VPS có IP public làm trạm trung gian: máy đích chủ động mở **reverse tunnel** ra VPS, và bạn SSH vào VPS để đi tiếp vào máy đích. Cũng dùng được để expose port bất kỳ khác (web app, database...) theo cùng cơ chế.

```
[Thiết bị của bạn] --ssh--> [VPS, IP public] <--reverse tunnel-- [Máy đích, sau NAT]
```

Gồm 2 script, chạy theo thứ tự **VPS trước, máy đích sau** (máy đích sẽ in ra public key để bạn dán vào VPS, nên có thể phải quay lại VPS chạy lần nữa):

| Script | Chạy ở | Làm gì |
|---|---|---|
| `vps_setup.sh` | VPS, bằng root | Tạo 1 user "chỉ dùng để tunnel": không có shell, không login được, chỉ được forward đúng các port bạn khai báo. Ghi cấu hình riêng vào `/etc/ssh/sshd_config.d/00-tunnel-<user>.conf`, không sửa `sshd_config` gốc. Tự kiểm chứng bằng `sshd -T -C`. |
| `local_setup.sh` | Máy đích | Tạo key, tự cài gói còn thiếu (autossh, openssh-server...), tạo service nền để tunnel luôn sống và tự chạy lại khi mất mạng hoặc khởi động máy. Có thể tạo thêm remote user (key riêng, password tuỳ chọn) cho nhiều người dùng chung 1 máy. |

**Lệnh chạy:**

```bash
# 1) Trên VPS (cần root)
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/nguyenhungbk96/quick-install/main/ssh-tunnel/vps_setup.sh)"

# 2) Trên máy đích sau NAT
bash -c "$(curl -fsSL https://raw.githubusercontent.com/nguyenhungbk96/quick-install/main/ssh-tunnel/local_setup.sh)"
```

**Chạy `local_setup.sh` bằng user thường hay root?**

| | User thường | Root (`sudo bash -c ...`) |
|---|---|---|
| Phù hợp | Máy cá nhân, tự SSH vào chính tài khoản của mình | Provisioning: root tạo sẵn user + key cho người khác |
| Service nền | LaunchAgent (macOS) / `systemd --user` (Linux), gắn với phiên đăng nhập | LaunchDaemon / systemd system unit, chạy từ lúc boot |
| Máy headless/server | Cần bật `linger` | **Nên chọn**: tunnel sống kể cả khi không ai đăng nhập |

**Hỏi gì trong lúc chạy:** tên user tunnel (mặc định `tunneluser`), public key, danh sách port cho phép forward (mặc định `2222 3000`), IP VPS, port cần map. Tất cả đều có giá trị mặc định, nhấn Enter để chấp nhận.

**Kết quả:** script chỉ báo `✔ HOÀN TẤT` khi đã kiểm chứng cấu hình thực sự có hiệu lực, nếu không sẽ báo `✘ CẢNH BÁO` kèm hướng dẫn gỡ lỗi. Cả 2 script đều **idempotent**, chạy lại để đổi port hoặc thêm port mới là an toàn.

**Tài liệu đầy đủ** (kiến trúc, 2 phương án sinh keypair, nhiều remote user, thêm port, xử lý sự cố): [ssh-tunnel/README.md](ssh-tunnel/README.md).

---

## An toàn khi chạy script từ internet

Các script ở đây thường **cần root và sửa cấu hình hệ thống** (sshd, service nền, cài gói). Chạy `curl` thẳng vào `bash` nghĩa là bạn tin hoàn toàn vào nội dung tại URL đó. Nên:

- **Đọc script trước khi chạy** (xem mục "Tải về đọc trước rồi chạy").
- **Ghim phiên bản** bằng tag/commit khi dùng cho máy quan trọng.
- Chỉ chạy script từ repo bạn tin cậy, kiểm tra kỹ owner và tên repo trong URL.
- Repo phải ở chế độ **public** thì link `raw.githubusercontent.com` mới tải được mà không cần đăng nhập.

---

## Cấu trúc repo

```
quick-install/
├── README.md              # file này: mục lục + cách chạy chung
└── ssh-tunnel/            # 1 thư mục = 1 tool
    ├── README.md          # hướng dẫn đầy đủ của tool
    ├── vps_setup.sh
    └── local_setup.sh
```

Quy ước: **mỗi tool một thư mục** ở gốc, trong đó có `README.md` riêng và các script `.sh` của tool đó. Tên thư mục dùng chữ thường, nối bằng dấu gạch ngang.

---

## Thêm tool / script mới

1. Tạo thư mục `<tên-tool>/` ở gốc repo, đặt các script `.sh` vào đó.
2. Viết `<tên-tool>/README.md`: bài toán giải quyết, yêu cầu, thứ tự chạy, script hỏi gì, cách gỡ cài đặt.
3. Cập nhật file này: thêm 1 dòng vào bảng [Danh sách tool](#danh-sách-tool), thêm 1 mục vào [Chi tiết từng tool](#chi-tiết-từng-tool) (theo khuôn của `ssh-tunnel`: bài toán, bảng script, lệnh chạy, hỏi gì, kết quả, link tài liệu), và cập nhật [Cấu trúc repo](#cấu-trúc-repo).
4. Yêu cầu với mỗi script, để chạy đúng khi gọi bằng `curl`:
   - Dòng đầu `#!/usr/bin/env bash`, có `set -euo pipefail`.
   - Có `SCRIPT_VERSION` và in ra khi chạy.
   - Hỏi tương tác thì đọc stdin trước, hết stdin mới fallback `/dev/tty` (xem hàm `ask()` trong `ssh-tunnel/local_setup.sh`).
   - Không phụ thuộc đường dẫn của chính file script (`$0`, `BASH_SOURCE`), vì khi chạy bằng `bash -c` các biến này không trỏ tới file thật.
   - Idempotent: chạy lại không làm hỏng trạng thái đã có.
   - Tự kiểm chứng kết quả thật rồi mới báo thành công.
   - Cần root thì kiểm tra `$EUID` ở đầu và báo lỗi rõ ràng.
