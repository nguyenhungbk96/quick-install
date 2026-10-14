# Hướng dẫn cài đặt SSH Tunnel (3 Máy: Local ↔ VPS ↔ Client)

Kết nối SSH từ **Máy Client** vào **Máy Local** (sau NAT/CGNAT/WSL) thông qua **Máy VPS** có IP public cố định.

| Máy | Vai trò | Thao tác |
| :--- | :--- | :--- |
| **1. Máy Local** | Máy đích cần được SSH vào | Chạy `local_setup.sh` |
| **2. Máy VPS** | Máy trung gian có IP public | Chạy `vps_setup.sh` |
| **3. Máy Client** | Máy bạn ngồi gõ lệnh SSH | Dán lệnh chép key + `~/.ssh/config` (in sẵn ở cuối Bước 1) |

---

## Cài đặt từng bước

### Bước 1 — Trên Máy Local (Tạo Key)

Chạy cho user hiện tại trên **Máy Local**:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/nguyenhungbk96/quick-install/main/ssh-tunnel/local_setup.sh)"
```

Hoặc chạy bằng `root` (dành cho server chạy nền từ lúc bật máy):

```bash
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/nguyenhungbk96/quick-install/main/ssh-tunnel/local_setup.sh)"
```

1. Đường dẫn lưu key: Nhấn **Enter** để chọn mặc định (`~/.ssh/vps_tunnel`).
2. **Copy dòng Public Key** (`ssh-ed25519 AAAA...`) hiển thị trên màn hình.
3. Giữ nguyên cửa sổ terminal Máy Local ở dòng chờ *"Đã setup xong user tunnel trên VPS chưa?"*, chuyển sang **Bước 2**.

---

### Bước 2 — Trên Máy VPS (Mở cổng Tunnel)

SSH vào **Máy VPS** và chạy:

```bash
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/nguyenhungbk96/quick-install/main/ssh-tunnel/vps_setup.sh)"
```

1. **Tên user tunnel**: Nhấn **Enter** (`tunneluser`) hoặc nhập tên tuỳ ý (vd: `jump`).
2. **Public key**: Dán dòng Public Key vừa copy từ Máy Local.
3. **Danh sách port**: Nhập cổng sẽ mở trên VPS cho Máy Local này (bắt buộc nhập, mỗi Máy Local 1 cổng riêng):
   - Chỉ mở SSH: nhập `2223`
   - Mở SSH + thêm cổng web app: nhập `2223 8080`

Khi VPS báo `✔ HOÀN TẤT`, **quay lại cửa sổ terminal Máy Local** (ở Bước 1):
1. Nhấn **Enter** để tiếp tục.
2. **IP hoặc domain của VPS**: Nhập IP của VPS.
3. **Tên user tunnel trên VPS**: Nhập khớp với tên đã tạo trên VPS (`tunneluser` hoặc `jump`).
4. **Port map** (`remote_port:local_port`):
   - SSH vào Máy Local (cổng 22): nhập `2223:22`
   - SSH (22) + web app local (3000): nhập `2223:22 8080:3000`
5. **Tạo remote user? (y/N)**:
   - Nhấn **Enter (`n`)** nếu chỉ mình bạn dùng tài khoản hiện tại.
   - Nhập **`y`** nếu muốn tạo thêm tài khoản và key riêng cho người khác.

---

### Bước 3 — Trên Máy Client (Kết nối SSH)

Sau khi Máy Local chạy xong, màn hình cuối cùng sẽ in sẵn phần **`HƯỚNG DẪN KẾT NỐI TỪ MÁY CLIENT`**. Mở terminal trên **Máy Client** và làm đúng 3 bước được in ra:

1. **Tạo Private Key trên Máy Client** (dán nguyên dòng lệnh `base64` từ màn hình Máy Local):

```bash
mkdir -p ~/.ssh && chmod 700 ~/.ssh && echo '<CHUỖI_BASE64>' | (base64 -d 2>/dev/null || base64 -D) > ~/.ssh/vps_tunnel && chmod 600 ~/.ssh/vps_tunnel && ssh-keygen -y -f ~/.ssh/vps_tunnel
```

*(Lưu ý: Không cần add thêm SSH key của Máy Client lên Máy Local vì key này đã được cấp quyền ở cả VPS và Máy Local).*

2. **Thêm cấu hình vào `~/.ssh/config` trên Máy Client**:

```ssh-config
Host vps-jump
    HostName <IP_VPS>
    User <user_tunnel_vps>
    IdentityFile ~/.ssh/vps_tunnel
    IdentitiesOnly yes
    ServerAliveInterval 30
    ServerAliveCountMax 3
    TCPKeepAlive yes

Host home
    HostName localhost
    HostKeyAlias home
    Port <remote_port_vps>
    User <user_may_local>
    ProxyJump vps-jump
    IdentityFile ~/.ssh/vps_tunnel
    IdentitiesOnly yes
    ServerAliveInterval 30
    ServerAliveCountMax 3
    TCPKeepAlive yes
```

3. **Kết nối từ Máy Client**:

```bash
ssh home
```

---

## Thêm Máy Local thứ 2 vào cùng VPS

1. Trên **Máy Local 2**: chạy `local_setup.sh` → copy Public Key mới.
2. Trên **Máy VPS**: chạy lại `vps_setup.sh`, nhập **cùng tên user tunnel**, dán Public Key mới, và chỉ nhập **`remote_port` mới** (vd `2224` — các port và key của Máy 1 được giữ nguyên).
3. Quay lại **Máy Local 2**: nhập Port map `2224:22`.
4. Trên **Máy Client**: đặt tên Host mới trong `~/.ssh/config` (vd `Host home-2` với `Port 2224`).

---

## Lệnh quản lý Tunnel (Chạy trên Máy Local)

| Việc cần làm | Linux (chạy bằng user thường) | Linux (chạy bằng `sudo`/root) | macOS |
| :--- | :--- | :--- | :--- |
| **Xem trạng thái** | `systemctl --user status vpstunnel-*.service` | `sudo systemctl status vpstunnel-*.service` | `launchctl list \| grep vpstunnel` |
| **Xem log** | `journalctl --user -u vpstunnel-*.service -f` | `sudo journalctl -u vpstunnel-*.service -f` | `tail -f /tmp/com.*.vpstunnel.*.err.log` |
| **Khởi động lại** | `systemctl --user restart vpstunnel-*.service` | `sudo systemctl restart vpstunnel-*.service` | `launchctl unload <plist> && launchctl load -w <plist>` |
| **Xoá tunnel cũ** | `systemctl --user disable --now <service>` | `sudo systemctl disable --now <service>` | `launchctl unload -w <plist>` |

---

## Xử lý lỗi khi không kết nối được

| Lỗi gặp trên Máy Client | Nguyên nhân & Cách sửa |
| :--- | :--- |
| **`<user>@<IP_VPS>: Permission denied (publickey)`** | • Sai IP VPS hoặc `User` trong `Host vps-jump` của `~/.ssh/config` trên Máy Client.<br>• Hoặc trong `~/.ssh/config` bị trùng một khối `Host vps-jump` cũ ở phía trên → mở `~/.ssh/config` xoá khối cũ.<br>• Hoặc chưa dán đúng Public Key lên VPS → chạy lại `vps_setup.sh` trên VPS. |
| **`<user>@localhost: Permission denied (publickey)`** | • Sai tên `User` của Máy Local trong khối `Host home` trên Máy Client.<br>• Hoặc thiếu key trong `~/.ssh/authorized_keys` của user đó trên Máy Local. |
| **`WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!`** | • Port `[localhost]:<port>` trên Máy Client từng lưu host key của máy khác.<br>• Chạy trên Máy Client: `ssh-keygen -R "[localhost]:<port>"` và thêm dòng `HostKeyAlias <tên_host>` vào dưới `Host` trong `~/.ssh/config`. |
| **`Connection refused` / `Connection closed by UNKNOWN`** | • Tunnel trên Máy Local chưa chạy hoặc sai `Port` → kiểm tra trạng thái service trên Máy Local.<br>• Kiểm tra port đã mở trên VPS chưa: chạy `sudo ss -tlnp \| grep <remote_port>` trên VPS. |
