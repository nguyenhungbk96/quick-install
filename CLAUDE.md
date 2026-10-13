# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repo là gì

Kho script cài đặt nhanh, người dùng chạy thẳng từ `main` bằng `bash -c "$(curl -fsSL https://raw.githubusercontent.com/nguyenhungbk96/quick-install/main/<tool>/<script>.sh)"`. Hiện chỉ có 1 tool: `ssh-tunnel/` (reverse SSH tunnel qua VPS). Mỗi tool một thư mục ở gốc, có `README.md` riêng; README gốc giữ mục lục và quy ước thêm tool mới.

Vì người dùng chạy trực tiếp từ `main`, **một lỗi cú pháp đẩy lên `main` làm hỏng ngay mọi người dùng**. Luôn kiểm tra cú pháp trước khi commit.

## Lệnh

Không có build, lint hay test suite. Chỉ có:

```bash
bash -n ssh-tunnel/vps_setup.sh && bash -n ssh-tunnel/local_setup.sh   # kiểm tra cú pháp
```

Script cần root/sshd/systemd thật nên không chạy thử trực tiếp trên macOS của máy dev. Các comment trong code ghi nhiều lỗi được tái hiện bằng Docker (kể cả chạy bằng root); muốn test hành vi thì dùng container Linux.

## Kiến trúc `ssh-tunnel`

Hai script chạy ở hai máy khác nhau, nối với nhau qua public key và `remote_port`:

- `vps_setup.sh` (root, trên VPS): tạo user tunnel-only (`nologin`, `ForceCommand /usr/sbin/nologin`) và ghi cấu hình sshd.
- `local_setup.sh` (máy sau NAT, macOS/Linux/WSL, user thường hoặc root): tạo key, cài autossh, dựng service nền mở `-R 127.0.0.1:<remote_port>:localhost:<local_port>` ra VPS. Có thể tạo thêm remote user (key riêng) trên máy đó.

Luồng đúng: `local_setup.sh` sinh key và in public key → `vps_setup.sh` nhận key + `remote_port` → quay lại `local_setup.sh` nhập IP VPS, user, port map `remote_port:local_port`. Người dùng cuối `ProxyJump` qua user tunnel vào máy đích.

Những điều phải đọc nhiều chỗ mới thấy:

- **Cấu hình sshd nằm ở drop-in riêng** `/etc/ssh/sshd_config.d/00-tunnel-<user>.conf`, không đụng `sshd_config` gốc. Tiền tố `00-` là có chủ đích: sshd lấy giá trị đầu tiên nhận được, kể cả trong `Match`, nên file nạp sớm thắng. Script tự phát hiện file khác cũng `Match User` cùng tên và tự verify bằng `sshd -T -C` ở bước cuối. Giữ nguyên cơ chế verify này khi sửa.
- **Một user tunnel phục vụ nhiều máy.** Key được append vào `authorized_keys` (không ghi đè). `PermitListen` được gộp từ drop-in cũ cộng với port mới nhập. Ai sửa phần này phải giữ tính cộng dồn, vì ghi đè đã từng cắt tunnel của máy khác. Chỉ thêm, chưa có chức năng gỡ key/port.
- **Hai cách chạy của `local_setup.sh` tạo service khác bản chất:** user thường dùng `systemd --user`/LaunchAgent (cần linger), root dùng systemd system unit/LaunchDaemon. Chạy bằng root thì `$SUDO` rỗng; viết `$SUDO VAR=1 cmd` sẽ hỏng, phải dùng `$SUDO env VAR=1 cmd`. Root mặc định không authorize key cho chính root.
- **Cả hai script đều tự kiểm chứng kết quả thật** rồi mới báo `✔ HOÀN TẤT`; không thêm đường báo thành công nếu chưa verify. Nguyên tắc "cảnh báo to, không im lặng": cảnh báo đi ra stderr, và tránh `exec` không kèm lệnh vì nó nuốt stderr cả script (đã gây bug).

## Quy ước khi sửa script

- **Hỏi tương tác phải đọc stdin trước, hết stdin mới fallback `/dev/tty`** (hàm `ask()` trong `local_setup.sh`). Không đọc `/dev/tty` trước, vì sẽ treo khi đưa câu trả lời qua pipe. `vps_setup.sh` dùng `read -r -p` trực tiếp.
- Không dùng `$0`/`BASH_SOURCE`: script chạy qua `bash -c "$(curl ...)"` nên không có file thật. Không hướng dẫn `curl ... | bash` vì stdin bị nuốt.
- `set -euo pipefail` nên cẩn thận với mảng rỗng (`set -u`) và `awk ... exit` trong pipe (SIGPIPE 141 làm chết script).
- `local_setup.sh` chạy trên macOS nên phải tương thích bash 3.2 (không dùng `mapfile`, mảng kết hợp...).
- **Không có port mặc định** cho `remote_port` ở cả hai script: bắt buộc nhập, in sẵn ví dụ. Có chủ đích, vì mặc định chung làm các máy dùng chung VPS đụng port nhau. Đừng đưa lại mặc định.
- Cả hai script in lộ trình ngắn 3 bước (LOCAL → VPS → LOCAL) bằng heredoc `'GUIDE'` trước câu hỏi đầu tiên; giữ ngắn, đừng thêm giải thích từng câu hỏi. Đổi luồng hỏi thì cập nhật cả hai bản cho khớp.
- Cuối `vps_setup.sh` in khối "NHẬP CÁC THÔNG TIN SAU VÀO local_setup.sh": IP VPS (hỏi `api.ipify.org`, lỗi thì `hostname -I`), tên user, và port map gợi ý. Port map chỉ lấy từ port nhập ở lần chạy này (`NEW_PORTS`), không lấy từ port cộng dồn của máy khác. Nếu sshd VPS không nghe port 22 thì có cảnh báo, vì `local_setup.sh` gọi `ssh`/autossh tới VPS không kèm `-p`.
- Mỗi lần sửa hành vi: tăng `SCRIPT_VERSION` ở đầu script **và** số phiên bản được nhắc cứng trong `ssh-tunnel/README.md` (mục mô tả hai script). README gốc và README của tool mô tả prompt/mặc định, nên cập nhật cùng lúc.
- Ngôn ngữ của script, comment và README là tiếng Việt; giữ nguyên.

## Lỗ hổng đã biết (chưa sửa)

Drop-in chỉ đặt `PermitListen` (chặn `-R`) mà không đặt `PermitOpen`, trong khi `AllowTcpForwarding yes` nên key nào đã đăng ký cũng dùng `-L`/`ProxyJump` đi tới host/port bất kỳ mà VPS truy cập được. Các key cũng không bị gắn với port riêng (`permitlisten=` trong `authorized_keys`), nên máy này chiếm được port của máy kia. README ghi "không thể forward port khác dù có đúng key" chỉ đúng với `-R`.
