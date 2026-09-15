# Reverse SSH Tunnel — truy cập máy sau NAT từ mọi nơi

Bộ 2 script này giúp bạn SSH vào một máy **không có IP public** (máy ở nhà, laptop
qua WSL, máy sau router/CGNAT...) từ bất kỳ đâu trên Internet, thông qua 1 VPS có
IP public làm trạm trung gian. Cũng dùng để expose bất kỳ port nào khác của máy đó
(web app, database...) ra ngoài theo cùng cơ chế.

- `vps_setup.sh` (v1.1.1) — chạy **trên VPS**, tạo 1 user "chỉ dùng để tunnel"
  (không có shell, không login được, chỉ forward đúng các port bạn chỉ định).
- `local_setup.sh` (v1.5.0) — chạy **trên máy muốn được truy cập từ xa**, tự tạo
  key, tự cài các gói cần thiết, tự tạo service nền để tunnel luôn sống. Ở cuối
  script còn hỏi tuỳ chọn tạo thêm **remote user khác** (full shell, chỉ đăng
  nhập bằng SSH key riêng) — dùng khi 1 máy cần cho nhiều người khác nhau remote
  vào bằng tài khoản + key riêng của từng người, thay vì dùng chung 1 tài khoản.

Cả 2 file đều **hỏi tương tác** (không cần sửa file hay nhớ tham số dòng lệnh),
và **tự kiểm chứng** kết quả thật trước khi báo thành công — không có kiểu
"chạy xong không lỗi" nhưng thực ra không hoạt động.

## Vì sao phải qua VPS (kiến trúc)

```
[Thiết bị của bạn]  --ssh-->  [VPS, IP public]  <--reverse tunnel--  [Máy đích, sau NAT]
   (laptop, phone)              (trạm trung gian)      (autossh tự "gọi ra" VPS)
```

Máy đích (ở nhà, sau router/CGNAT) **không có IP public** nên không ai từ Internet
gõ thẳng vào được. Máy đích tự chủ động "gọi ra" VPS trước (chiều nó gọi được),
giữ 1 đường tunnel luôn mở; từ đó bất kỳ ai có key đúng đều SSH vào VPS rồi nhảy
tiếp vào máy đích qua chính đường tunnel đó (`ProxyJump`).

> Nếu máy đích **có** thể setup DDNS + port forward trên router (có quyền admin
> router, không bị CGNAT), không cần VPS/tunnel gì cả — chỉ cần 1 `Host` đơn giản
> trỏ thẳng vào DDNS hostname + port đã forward. Cách trong README này dành cho
> trường hợp **không** có quyền đó.

## Yêu cầu

- 1 VPS có IP public, truy cập được qua SSH (đã có sẵn user quản trị + quyền sudo/root).
- Máy đích: chạy được bash, có kết nối Internet ra ngoài (không cần IP public,
  không cần cấu hình router).
- Cả 2 script **tự cài** mọi gói còn thiếu (autossh, openssh-server...) — không
  cần cài tay trước.

---

## Bước 1 — Setup VPS

Copy `vps_setup.sh` lên VPS rồi chạy bằng root:

```bash
scp vps_setup.sh <user>@<VPS_IP>:~/
ssh <user>@<VPS_IP>
sudo ./vps_setup.sh
```

Script sẽ hỏi:
1. **Tên user tunnel** (mặc định `tunneluser`) — tài khoản này sẽ được tạo, không
   có shell, không login được, chỉ dùng để nhận reverse tunnel.
2. **Public key** — dán nội dung hoặc đường dẫn file `.pub`. Nếu chưa có key, quay
   lại sau khi chạy `local_setup.sh` (Bước 2) vì nó sẽ tạo key và in ra cho bạn.
3. **Danh sách port** muốn cho phép forward (mặc định `2222 3000`) — đây là các
   port sẽ mở **trên VPS**, chỉ bind `127.0.0.1` (không lộ ra Internet), dùng làm
   "cửa vào" khi SSH qua VPS.

Script tự làm và **tự kiểm chứng lại bằng `sshd -T -C`** (đọc cấu hình sshd *thực
sự áp dụng* cho user đó, không chỉ đoán):
- Cài `openssh-server` nếu VPS chưa có.
- Tạo user, cài public key vào `authorized_keys`.
- Ghi cấu hình giới hạn vào `/etc/ssh/sshd_config.d/00-tunnel-<user>.conf` (không
  đụng vào `/etc/ssh/sshd_config` gốc — an toàn, dễ gỡ, chỉ cần xoá 1 file).
- Phát hiện nếu có file cấu hình khác cũng match cùng user (có thể gây xung đột
  im lặng) và cảnh báo.
- Restart sshd, verify lại `AllowTcpForwarding`/`PermitListen`/`ForceCommand`
  bằng dữ liệu thật.

Kết quả cuối: `✔ HOÀN TẤT` (đã xác nhận có hiệu lực) hoặc `✘ CẢNH BÁO` kèm hướng
dẫn debug cụ thể — không bao giờ báo thành công giả.

---

## Bước 2 — Setup máy đích (máy muốn được truy cập từ xa)

Chạy trên máy đích (macOS hoặc Linux, kể cả WSL):

```bash
./local_setup.sh
```

Script hỏi:
1. **Đường dẫn private key** (mặc định `~/.ssh/vps_tunnel`) — tự tạo mới nếu
   chưa có, rồi in ra public key để bạn copy sang chạy `vps_setup.sh` (Bước 1)
   nếu chưa làm.
2. Chờ bạn xác nhận đã setup xong VPS.
3. **IP/domain VPS** và **tên user tunnel** (khớp với Bước 1).
4. **Port map**, dạng `remote_port:local_port` (mặc định `2222:22 3000:3000`):
   - `remote_port`: port trên VPS (khớp danh sách đã khai ở Bước 1).
   - `local_port`: port tương ứng trên chính máy đích (`22` = SSH vào máy này,
     port khác = ứng dụng riêng của bạn, ví dụ web app).

Sau đó script tự động:
- **Cài `autossh`** nếu chưa có (brew/apt/dnf/yum/pacman/zypper/apk tuỳ máy).
- **Kiểm tra từng `local_port`** đã có gì lắng nghe chưa. Nếu là port `22` mà
  chưa có sshd → **tự cài `openssh-server`** và tự bật (Linux), hoặc tự bật
  "Remote Login" (macOS). Port khác thì chỉ cảnh báo (không tự biết cách chạy
  hộ ứng dụng của bạn).
- **Authorize luôn key đó** vào `~/.ssh/authorized_keys` của máy đích (nếu có
  forward port 22) — để lúc SSH vào máy đích qua tunnel **không bị hỏi password**.
- Ghi `~/.ssh/config` với 2 Host: `vps-jump` (nhảy qua VPS) và `home` (đích cuối,
  tự `ProxyJump` qua `vps-jump`).
- Tạo service nền tự chạy + tự reconnect: **LaunchAgent** (macOS) hoặc
  **`systemd --user`** (Linux) — tự bật `linger` để sống qua logout, retry vô
  hạn khi mạng chập chờn (`StartLimitIntervalSec=0`), và **tự verify** service
  thật sự đang `active`/loaded trước khi báo xong.

---

## Bước 3 — Setup thiết bị bạn dùng để SSH từ xa (làm 1 lần, dùng mãi mãi)

**Đây là bước hay bị hiểu nhầm nhất**: private key phải nằm trên **thiết bị bạn
ngồi gõ lệnh SSH** (laptop, điện thoại...) — không phải trên VPS, không phải
trên chính máy đích. VPS và máy đích chỉ cần giữ **public key**.

1. Trên máy đích, lấy nội dung private key:
   ```bash
   cat ~/.ssh/vps_tunnel
   ```
2. Trên thiết bị bạn sẽ dùng để SSH từ xa, tạo file và dán nội dung vào:
   ```bash
   mkdir -p ~/.ssh
   nano ~/.ssh/vps_tunnel_<ten_may_dich>
   chmod 600 ~/.ssh/vps_tunnel_<ten_may_dich>
   ```
3. Thêm vào `~/.ssh/config` của thiết bị đó:
   ```
   Host vps-jump
       HostName <VPS_IP>
       User tunneluser
       IdentityFile ~/.ssh/vps_tunnel_<ten_may_dich>

   Host home
       HostName localhost
       Port 2222
       User <user_that_tren_may_dich>
       ProxyJump vps-jump
       IdentityFile ~/.ssh/vps_tunnel_<ten_may_dich>
   ```
4. Dùng:
   ```bash
   ssh home
   ```

Lặp lại bước này cho từng thiết bị bạn muốn dùng để truy cập từ xa (đổi tên
`Host` nếu setup cho nhiều máy đích khác nhau, ví dụ `home_wsl`, `home_nas`...).

---

## Bước 4 (tuỳ chọn) — Thêm remote user khác trên máy đích

Mặc định, `local_setup.sh` chỉ authorize key cho **user hiện tại** trên máy đích
(người chạy script). Nếu muốn **người khác** cũng SSH vào được máy này bằng tài
khoản + key **riêng** của họ (không dùng chung tài khoản của bạn), **ngay cuối**
`local_setup.sh` (sau khi tunnel đã chạy xong) script sẽ hỏi:

```
Tạo thêm remote user khác trên máy này (để người khác SSH vào bằng tài khoản + key riêng)? (y/N):
```

Trả lời `y`, script hỏi tiếp:
1. **Tên user mới** muốn tạo trên máy này.
2. **Đường dẫn lưu keypair** riêng cho user đó (mặc định tự sinh mới).

Script tự động (dùng lại `$VPS_IP`/tên user tunnel/`remote_port` đã hỏi ở đầu
lần chạy này, không hỏi lại):
- Tạo user **full shell** (home dir + bash/zsh) nhưng **không đặt password** —
  chỉ đăng nhập được bằng SSH key (`passwd -l`/`usermod -L` trên Linux,
  `sysadminctl -password -` trên macOS).
- Trên macOS, nếu Remote Login đang giới hạn theo danh sách user/group
  (`com.apple.access_ssh`), tự thêm user mới vào group đó — nếu không, Remote
  Login mặc định cho "All users" nên không cần làm gì thêm.
- Sinh keypair ed25519 riêng, cài public key vào **đúng** `authorized_keys` của
  user mới (không đụng key của user khác).
- **Tự SSH test ngay hop cuối** (key mới đăng nhập thẳng vào `127.0.0.1` bằng
  đúng user mới tạo) — không cần chờ gì, biết ngay có OK hay không.

Việc đăng ký key lên VPS không phải chỉ là dòng hướng dẫn suông — script
**dừng lại chờ bạn xác nhận** đã làm xong bên VPS rồi mới tự test tiếp:

1. Script in ra public key vừa sinh + hướng dẫn: sang VPS, chạy lại
   `vps_setup.sh`, nhập đúng cùng user tunnel và **đúng cùng danh sách port
   như lần trước** (vps_setup.sh ghi đè toàn bộ port list mỗi lần chạy — nhập
   thiếu port cũ sẽ vô tình bịt mất port đó), dán public key đó vào khi được
   hỏi (`vps_setup.sh` tự **APPEND**, không xoá key người khác đã có).
2. Script **dừng lại** ở dòng "Đã dán public key ở trên vào vps_setup.sh trên
   VPS xong chưa? Nhấn Enter để tự kiểm tra..." — bạn làm xong bên VPS rồi mới
   quay lại đây nhấn Enter.
3. Script **tự SSH test hop đầu** (key mới nhảy qua VPS được chưa) và báo rõ
   OK hay CẢNH BÁO kèm chi tiết lỗi thật — không đoán, không im lặng.
4. In mẫu `~/.ssh/config` (`Host home-<user>`) để đưa cho người dùng thật.

Nhờ đăng ký key lên cả 2 nơi, mỗi remote user có 1 key độc lập xuyên suốt cả 2
hop — thu hồi quyền 1 người chỉ cần xoá đúng 1 key đó ở cả 2 nơi, không ảnh
hưởng ai khác.

Sau khi xong, script hỏi "Tạo thêm 1 remote user nữa? (y/N)" — lặp lại được bao
nhiêu người tuỳ ý trong cùng 1 lần chạy, không cần chạy lại toàn bộ script.

**Lưu ý bảo mật**: private key được sinh ra **trên chính máy đích** (máy bạn
vừa chạy script) — nếu người dùng là người khác, phải chuyển private key đó
cho họ qua kênh an toàn (scp/sftp) rồi **xoá khỏi máy đích**, giống hệt lưu ý
"Phương án B" ở cuối `vps_setup.sh` khi keypair lỡ sinh trên VPS thay vì trên
máy client.

---

## Vận hành hàng ngày

| Việc cần làm | Lệnh |
|---|---|
| SSH vào máy đích | `ssh home` (hoặc tên Host bạn đặt) |
| Xem log tunnel (Linux) | `journalctl --user -u vpstunnel-*.service -f` |
| Xem trạng thái tunnel (Linux) | `systemctl --user status vpstunnel-*.service` |
| Dừng tunnel (Linux) | `systemctl --user stop vpstunnel-*.service` |
| Khởi động lại tunnel (Linux) | `systemctl --user restart vpstunnel-*.service` |
| Xem log tunnel (macOS) | `tail -f /tmp/com.<user>.vpstunnel.*.log` |
| Dừng/chạy lại tunnel (macOS) | `launchctl unload/load -w ~/Library/LaunchAgents/com.<user>.vpstunnel.*.plist` |
| Kiểm tra port đã bind trên VPS chưa | `sudo ss -tlnp \| grep <remote_port>` |

Muốn đổi port map hoặc thêm port mới: chạy lại `local_setup.sh` (và
`vps_setup.sh` nếu thêm `remote_port` mới) — cả 2 script đều **idempotent**,
ghi đè cấu hình cũ hoàn toàn, không để lại rác.

---

## Troubleshooting — các lỗi thật đã gặp khi setup

### 1. `ssh` treo im lặng khi test kết nối
Đã fix trong script: không dùng `-N` khi chỉ muốn kiểm tra auth (vì `-N` giữ
session mở vô thời hạn chờ forward). Nếu bạn tự test bằng tay, nhớ bỏ `-N`
hoặc thêm `timeout`.

### 2. `ss -tlnp` trên VPS không thấy port nào listen dù script báo thành công
Nguyên nhân từng gặp: có **file cấu hình khác** trong
`/etc/ssh/sshd_config.d/` cũng match cùng user tunnel (ví dụ do 1 lần setup
tunnel khác trước đó), và nó được nạp **trước** file của script này nên thắng
theo quy tắc "giá trị đầu tiên nhận được thắng" của sshd — cấu hình của script
bị vô hiệu hoá âm thầm. `vps_setup.sh` từ bản v1.0.1 trở đi ghi vào
`00-tunnel-<user>.conf` (tiền tố `00-` luôn được nạp trước) và **tự verify**
bằng `sshd -T -C` — nếu vẫn bị đè, script sẽ báo `✘ CẢNH BÁO` kèm tên file gây
xung đột thay vì báo thành công giả.

### 3. VPS: `connect_to localhost port 22: failed` (xem trong
`journalctl --user -u vpstunnel-*.service`), hoặc từ VPS gõ
`ssh -p <port> ...@localhost` bị `Connection reset by peer` / `kex_exchange_identification`
Nghĩa là tunnel đã lên VPS thành công, nhưng **máy đích chưa có gì lắng nghe ở
local_port đó** (ví dụ chưa cài `sshd`). `local_setup.sh` từ v1.1.0 tự phát
hiện và tự cài/bật `openssh-server` cho trường hợp port 22; các port khác
(ứng dụng riêng của bạn) sẽ được cảnh báo rõ vì script không biết cách chạy hộ.

### 4. Đăng nhập qua tunnel cứ hỏi password dù đã setup key
Hai khả năng:
- **Bạn test trực tiếp trên VPS** bằng `ssh -p <port> user@localhost` mà không
  chỉ định `-i`: private key chỉ nằm trên máy bạn dùng để SSH (Bước 3), VPS
  không có key đó nên không tự "mượn" được — đây không phải lỗi, chỉ là test
  sai cách.
- **Máy đích chưa authorize key cho chính nó**: key `vps_tunnel` mặc định chỉ
  được VPS chấp nhận (để xác thực tunnel), chưa chắc đã được phép đăng nhập vào
  chính máy đích. `local_setup.sh` từ v1.2.0 tự thêm key vào
  `~/.ssh/authorized_keys` của máy đích nếu port map có forward tới port 22.

### 5. `WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!` khi SSH qua tunnel
Đây là cảnh báo về **host key của máy đích** (định danh máy chủ, khác hoàn
toàn với private key dùng để đăng nhập) — xảy ra khi sshd trên máy đích được
cài lại (sinh host key mới). Xác minh nhanh trên máy đích:
```bash
ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub
```
So khớp với fingerprint trong cảnh báo; nếu đúng, xoá entry cũ và chấp nhận key
mới **trên máy bạn đang SSH từ đó**:
```bash
ssh-keygen -R "[localhost]:<port>"
ssh home
```

### 6. `command -v systemctl` có nhưng service vẫn không chạy được
Container/WSL1/chroot đôi khi có sẵn binary `systemctl` nhưng không có systemd
PID 1 thật chạy phía sau (`Failed to connect to bus: Host is down`). Từ
v1.1.0, script không tin suông vào việc binary tồn tại — verify bằng
kết quả thật (port có nghe không) rồi mới fallback sang `service`.

---

## Bảo mật đã áp dụng

- User tunnel trên VPS: không có shell (`ForceCommand /usr/sbin/nologin`),
  không login được, không dùng password (`PasswordAuthentication no`).
- `PermitListen` giới hạn **đúng** các port đã khai báo — không thể forward
  port khác dù có đúng key.
- `GatewayPorts no`: port trên VPS chỉ bind `127.0.0.1`, không lộ ra Internet —
  bắt buộc phải SSH vào VPS trước rồi mới nhảy tiếp (`ProxyJump`), không ai từ
  ngoài gõ thẳng vào port đó được.
- Cấu hình VPS nằm ở file riêng (`sshd_config.d/00-tunnel-<user>.conf`), không
  đụng vào `sshd_config` gốc — dễ gỡ, dễ audit, không sợ phá cấu hình khác.
- `systemd` service của tunnel dùng `StartLimitIntervalSec=0`: tunnel tự
  retry vô hạn khi mạng chập chờn, không bao giờ "bỏ cuộc" âm thầm.

## Version

Cả 2 script in version ngay dòng đầu tiên khi chạy (`v$SCRIPT_VERSION`), kèm
`CHANGELOG` chi tiết trong comment đầu file — xem trực tiếp trong file `.sh`
để biết lịch sử các fix.
