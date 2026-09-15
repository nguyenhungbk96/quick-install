#!/usr/bin/env bash
#
# local_setup.sh — Setup máy local (macOS hoặc Linux) để tự động mở SSH reverse tunnel
# lên VPS, dùng autossh + service nền (LaunchAgent trên macOS, systemd --user trên Linux)
# để tự chạy lại khi mất mạng/khởi động máy.
#
# Chạy đơn giản:
#   ./local_setup.sh
# Script sẽ hỏi từng bước: tạo/chọn key, IP VPS, user tunnel, các port cần forward.
#
# CHANGELOG:
#   1.0.0 - Bản theo dõi version đầu tiên. Gồm các fix đã kiểm chứng bằng Docker:
#           fix test kết nối SSH bị treo (bỏ -N khi chỉ auth-check), autossh cài
#           qua apt/dnf/yum/pacman/brew tuỳ OS, service nền dùng systemd --user
#           (Linux, tự bật linger + verify bus trước khi start) hoặc LaunchAgent
#           (macOS), validate input (khoảng trắng phá cú pháp ExecStart/plist),
#           StartLimitIntervalSec=0 để tunnel retry vô hạn khi mạng chập chờn,
#           tự verify service active/loaded trước khi báo hoàn tất.
#   1.0.1 - Fix bug: chạy lại script với port map khác (vd đổi remote SSH port
#           2222 -> 2200) trước đây bị bỏ qua vì ~/.ssh/config đã có marker cũ,
#           giữ config lỗi thời. Giờ luôn xoá block cũ và ghi lại mới mỗi lần
#           chạy (idempotent thật sự, giống cách vps_setup.sh đã làm). Đã test
#           lại bằng Docker: chạy 2 lần với port khác nhau, xác nhận config
#           được cập nhật đúng, không trùng lặp.
#   1.1.0 - Thêm bước [2/5] tự kiểm tra + tự cài đặt service đích trên máy này:
#           nếu port map có local_port=22 mà chưa có gì lắng nghe, tự cài
#           openssh-server (Linux) hoặc tự bật Remote Login (macOS) rồi verify
#           lại bằng port thật (không cần cài thêm tool nào, dùng /dev/tcp có
#           sẵn của bash). Port khác không tự biết cách chạy hộ thì cảnh báo
#           rõ ràng thay vì để lỗi "connect_to localhost port X: failed" chỉ
#           lộ ra sau khi tunnel đã chạy. Fix thêm 1 bug thật: kiểm tra
#           `command -v systemctl` không đủ để biết systemd có thực sự chạy
#           (container/WSL1/chroot có thể có binary nhưng gọi vào lỗi "Host is
#           down") — giờ verify bằng port thật rồi mới fallback sang `service`,
#           đã tái hiện và xác nhận fix bằng Docker.
#   1.1.1 - Log rõ ràng hơn cho việc cài package: thêm hàm ensure_pkg in rõ
#           "đã có sẵn -> BỎ QUA" / "CHƯA có -> đang cài" / "CÀI THÀNH CÔNG" /
#           "CÀI THẤT BẠI" (dùng cho autossh, openssh-server), install_pkg in
#           rõ đang dùng trình quản lý gói nào, và bước bật sshd (systemctl/
#           service) cũng log rõ thử cách nào, cách nào thành công.
#   1.2.0 - Fix lỗ hổng thiết kế: key "vps_tunnel" trước đây chỉ được VPS chấp
#           nhận (xác thực tunnel), chưa được chính máy local authorize cho hop
#           cuối -> "ssh home"/forward vào port 22 luôn bị hỏi mật khẩu dù đã
#           setup xong. Giờ tự thêm public key vào chính
#           ~/.ssh/authorized_keys của user hiện tại (nếu port map có forward
#           tới local port 22), và thêm IdentityFile vào Host "home" trong ssh
#           config. Đã test bằng Docker: login qua tunnel với BatchMode=yes
#           (không cho hỏi password) thành công.
#   1.3.0 - Fix bug thật gặp trên WSL: bước [2/5] tự cài openssh-server trước đây
#           chỉ kiểm tra "binary sshd có tồn tại" để kết luận đã cài xong, nên có
#           thể báo "đã có sẵn -> BỎ QUA" dù gói thực ra cài dở dang/thiếu hẳn unit
#           systemd (`sudo systemctl status ssh` báo "Unit ssh.service could not
#           be found") -> tunnel vẫn được tạo xong nhưng forward vào port 22 luôn
#           lỗi "Connection closed" mà không có cảnh báo rõ ràng lúc setup. Giờ
#           kiểm tra qua package manager (dpkg/rpm/pacman/apk) thay vì chỉ tin
#           binary, và nếu systemctl enable báo "could not be found" thì tự cài
#           lại + enable lại thay vì bỏ cuộc.
#   1.4.0 - 2 fix thật gặp khi debug live trên WSL (Ubuntu, không có systemd PID 1
#           sẵn sàng lúc apt chạy):
#           a) `apt-get install openssh-server` có thể làm dpkg lỗi hẳn
#              ("Could not execute systemctl ... dpkg: error processing package")
#              vì postinst của gói tự gọi systemctl để enable service ngay trong
#              lúc cài, mà lúc đó systemd chưa sẵn sàng nhận lệnh. Giờ cài qua apt
#              với biến môi trường SYSTEMD_OFFLINE=1 (cơ chế chính thức của
#              deb-systemd-helper để báo "đừng tự gọi systemctl lúc cài, để tôi tự
#              enable/start sau") — bước enable/start thật vẫn do chính script
#              làm ở phần sau như cũ, chỉ tránh crash lúc cài.
#           b) Root cause thật sự khiến cả buổi debug: user gõ port map dạng
#              remote_port:local_port nhưng nhập nhầm local_port trùng
#              remote_port (vd "2224:2224" thay vì "2224:22") — sshd chạy đúng ở
#              port 22 nhưng tunnel lại trỏ vào port 2224 (không ai lắng nghe).
#              Script cũ CÓ cảnh báo lúc [2/5] nhưng chỉ 1 dòng giữa hàng chục
#              dòng log khác nên bị bỏ sót, chỉ phát hiện được sau khi debug từ
#              xa rất lâu. Giờ mọi port map chưa xác nhận sẵn sàng được gom lại
#              và in thành 1 bảng CẢNH BÁO riêng, to, ở NGAY CUỐI script (sau khi
#              đã báo cài đặt xong) — không thể lướt qua được nữa.
#   1.5.0 - Thêm bước [Tuỳ chọn] ở cuối script: tạo thêm "remote user" khác trên
#           chính máy đích, để nhiều người khác nhau cùng SSH vào máy này bằng
#           tài khoản + key riêng của từng người (không phải chỉ user chạy
#           script). Mỗi user tạo ra có full shell nhưng KHÔNG đặt password —
#           chỉ đăng nhập được bằng SSH key riêng (khoá password bằng
#           passwd -l/usermod -L trên Linux, sysadminctl -password - trên
#           macOS). Tự sinh keypair ed25519 riêng cho từng user, cài public key
#           vào đúng authorized_keys của user đó, tự thêm vào group
#           com.apple.access_ssh nếu Remote Login trên macOS đang giới hạn theo
#           danh sách user/group, và nhắc rõ 2 việc hay bị quên: (1) phải
#           chuyển private key an toàn cho đúng người rồi xoá khỏi máy đích,
#           (2) key đó còn phải được ĐĂNG KÝ THÊM trên VPS (chạy lại
#           vps_setup.sh) thì mới ProxyJump qua VPS được — nếu không hop đầu sẽ
#           luôn fail dù key đúng cho hop cuối. Giống hệt cách luồng tunnel
#           chính đã làm (chờ xác nhận + tự verify thật bằng SSH thay vì chỉ in
#           hướng dẫn rồi tin suông): tự SSH test hop cuối (vào máy này) ngay
#           sau khi cài key — không cần chờ gì; rồi DỪNG LẠI chờ bạn xác nhận
#           đã đăng ký key lên VPS xong mới tự SSH test tiếp hop đầu (nhảy qua
#           VPS) — báo rõ CẢNH BÁO kèm chi tiết lỗi nếu 1 trong 2 hop chưa
#           thông, thay vì chỉ đưa hướng dẫn rồi im lặng không biết đã đúng hay
#           chưa.
#
SCRIPT_VERSION="1.5.0"

set -euo pipefail

OS="$(uname -s)"
KEY_DEFAULT="$HOME/.ssh/vps_tunnel"

# Script hỗ trợ 2 kiểu chạy, KHÁC NHAU CƠ BẢN ở chỗ service nền được cài ở đâu:
#   a) Chạy bằng USER THƯỜNG (cách cũ): tự gọi sudo khi cần; tunnel chạy bằng
#      service THEO USER (systemd --user / LaunchAgent) — chỉ sống theo phiên
#      đăng nhập của user đó (cần linger để sống qua logout).
#   b) Chạy bằng ROOT (provisioning: root tạo user + key, người dùng thật SSH
#      vào các user đó): KHÔNG dùng được systemd --user/LaunchAgent vì root
#      thường không có phiên đăng nhập desktop/dbus thật -> phải cài service
#      HỆ THỐNG (systemd system unit / LaunchDaemon), tự chạy từ lúc boot,
#      không phụ thuộc ai đăng nhập. Ngoài ra nhiều image tối giản chạy bằng
#      root còn KHÔNG cài sẵn lệnh 'sudo' -> gọi thẳng, không qua sudo.
# $USER không phải lúc nào cũng có (vd `su` không dùng '-', `docker exec`, cron):
# script dùng $USER ở nhiều chỗ mà `set -u` sẽ làm chết script nếu biến trống.
USER="${USER:-$(id -un)}"

if [[ $EUID -eq 0 ]]; then
  IS_ROOT=1
  SUDO=""
  echo "    [chế độ] Đang chạy bằng ROOT -> tunnel sẽ được cài làm SERVICE HỆ THỐNG."
else
  IS_ROOT=0
  SUDO="sudo"
fi

echo "=== Setup SSH reverse tunnel (máy local) — local_setup.sh v$SCRIPT_VERSION ==="
echo ""

read -r -p "Đường dẫn private key muốn dùng [$KEY_DEFAULT]: " KEY_PATH
KEY_PATH="${KEY_PATH:-$KEY_DEFAULT}"
KEY_PATH="${KEY_PATH/#\~/$HOME}"
if [[ "$KEY_PATH" == *' '* ]]; then
  echo "Lỗi: đường dẫn key không được chứa khoảng trắng (sẽ phá cú pháp file service/plist sinh ra)." >&2
  exit 1
fi

if [[ -f "$KEY_PATH" ]]; then
  echo "    Đã có key tại $KEY_PATH, dùng lại key này."
else
  echo "    Chưa có key tại $KEY_PATH."
  read -r -p "Tạo mới key ed25519 tại đây? (Y/n): " ans
  if [[ "$ans" =~ ^[Nn]$ ]]; then
    echo "Dừng lại. Hãy chạy lại và trỏ đúng key đã có." >&2
    exit 1
  fi
  ssh-keygen -t ed25519 -f "$KEY_PATH" -N "" -C "vps-tunnel-$(date +%Y%m%d)"
  echo ""
  echo "    Đã tạo keypair: $KEY_PATH (private) / $KEY_PATH.pub (public)"
fi

echo ""
echo "==> Nội dung public key (cần dán/copy sang VPS khi chạy vps_setup.sh):"
echo "----------------------------------------------------------------------"
cat "$KEY_PATH.pub"
echo "----------------------------------------------------------------------"
read -r -p "Đã setup xong user tunnel trên VPS (chạy vps_setup.sh) chưa? Nhấn Enter để tiếp tục..." _

echo ""
read -r -p "IP hoặc domain của VPS: " VPS_IP
while [[ -z "$VPS_IP" || "$VPS_IP" == *' '* ]]; do
  read -r -p "IP/domain không hợp lệ hoặc trống. Nhập lại: " VPS_IP
done

read -r -p "Tên user tunnel trên VPS [tunneluser]: " TUNNEL_USER
TUNNEL_USER="${TUNNEL_USER:-tunneluser}"
if [[ "$TUNNEL_USER" == *' '* ]]; then
  echo "Lỗi: tên user không được chứa khoảng trắng." >&2
  exit 1
fi

echo ""
echo "Nhập danh sách port muốn forward, dạng remote_port:local_port, cách nhau bởi dấu cách."
echo "  remote_port : port sẽ mở trên VPS (chỉ bind localhost VPS, dùng qua SSH jump)"
echo "  local_port  : port tương ứng trên máy bạn"
read -r -p "Port map [2222:22 3000:3000]: " PORT_MAPS_RAW
PORT_MAPS_RAW="${PORT_MAPS_RAW:-2222:22 3000:3000}"
read -r -a PORT_MAPS <<< "$PORT_MAPS_RAW"

# Cài 1 package qua bất kỳ package manager nào có sẵn trên máy (brew/apt/dnf/yum/
# pacman/zypper/apk). Dùng chung cho autossh và openssh-server để tránh lặp code.
# In rõ đang dùng trình quản lý gói nào để dễ theo dõi log.
install_pkg() {
  local pkg="$1"
  if command -v brew &>/dev/null; then
    echo "    [gói] dùng brew để cài '$pkg'..."
    brew install "$pkg"
  elif command -v apt-get &>/dev/null; then
    echo "    [gói] dùng apt-get để cài '$pkg'..."
    $SUDO apt-get update -y -qq
    # SYSTEMD_OFFLINE=1: báo cho deb-systemd-helper biết đừng tự gọi systemctl
    # ngay trong lúc cài (postinst). Trên WSL, gọi systemctl lúc systemd chưa kịp
    # sẵn sàng có thể làm cả gói bị lỗi hẳn ("Could not execute systemctl ...
    # dpkg: error processing package") — bước enable/start thật vẫn do chính
    # script này làm tường minh ở bước sau, nên an toàn khi tắt auto-enable ở đây.
    $SUDO SYSTEMD_OFFLINE=1 apt-get install -y "$pkg"
  elif command -v dnf &>/dev/null; then
    echo "    [gói] dùng dnf để cài '$pkg'..."
    $SUDO dnf install -y "$pkg"
  elif command -v yum &>/dev/null; then
    echo "    [gói] dùng yum để cài '$pkg'..."
    $SUDO yum install -y "$pkg"
  elif command -v pacman &>/dev/null; then
    echo "    [gói] dùng pacman để cài '$pkg'..."
    $SUDO pacman -Sy --noconfirm "$pkg"
  elif command -v zypper &>/dev/null; then
    echo "    [gói] dùng zypper để cài '$pkg'..."
    $SUDO zypper install -y "$pkg"
  elif command -v apk &>/dev/null; then
    echo "    [gói] dùng apk để cài '$pkg'..."
    $SUDO apk add "$pkg"
  else
    echo "    [gói] '$pkg': CÀI THẤT BẠI — không tìm được trình quản lý gói phù hợp (brew/apt/dnf/yum/pacman/zypper/apk)." >&2
    return 1
  fi
}

# Kiểm tra 1 lệnh/binary đã có chưa; nếu chưa thì cài qua install_pkg, rồi verify
# lại. In rõ từng trạng thái: BỎ QUA (đã có sẵn) / ĐANG CÀI / CÀI THÀNH CÔNG /
# CÀI THẤT BẠI — để luôn biết chính xác gói nào được cài, gói nào được skip.
ensure_pkg() {
  local desc="$1" check_cmd="$2" pkg="$3"
  if eval "$check_cmd" &>/dev/null; then
    echo "    [gói] $desc: đã có sẵn -> BỎ QUA cài đặt."
    return 0
  fi
  echo "    [gói] $desc: CHƯA có -> đang cài package '$pkg'..."
  install_pkg "$pkg"
  if eval "$check_cmd" &>/dev/null; then
    echo "    [gói] $desc: CÀI THÀNH CÔNG."
    return 0
  else
    echo "    [gói] $desc: CÀI THẤT BẠI (đã chạy lệnh cài nhưng vẫn không thấy)." >&2
    return 1
  fi
}

# Kiểm tra gói openssh-server đã thực sự cài xong chưa bằng chính package manager,
# thay vì chỉ tin "binary sshd tồn tại trong PATH/vị trí quen thuộc" — cách cũ có
# thể báo dương tính giả khi cài dở dang (binary sót lại nhưng thiếu hẳn unit
# systemd), khiến script tưởng đã xong nên bỏ qua bước cài, còn tunnel thì vẫn
# tạo được nhưng port 22 không bao giờ có ai lắng nghe (bug thật gặp trên WSL).
sshd_really_installed() {
  if command -v dpkg &>/dev/null; then
    dpkg -s openssh-server &>/dev/null && return 0
    return 1
  elif command -v rpm &>/dev/null; then
    rpm -q openssh-server &>/dev/null && return 0
    return 1
  elif command -v pacman &>/dev/null; then
    pacman -Qi openssh &>/dev/null && return 0
    return 1
  elif command -v apk &>/dev/null; then
    apk info -e openssh-server &>/dev/null && return 0
    return 1
  fi
  # Không nhận diện được package manager: đành fallback về kiểm tra binary.
  command -v sshd &>/dev/null || [[ -x /usr/sbin/sshd ]]
}

# Kiểm tra 1 port trên 127.0.0.1 có đang có gì lắng nghe không, không cần cài thêm
# công cụ gì (dùng tính năng /dev/tcp có sẵn của bash).
port_is_listening() {
  local port="$1"
  (exec 3<>"/dev/tcp/127.0.0.1/${port}") 2>/dev/null && { exec 3>&- 2>/dev/null; return 0; }
  return 1
}

# Lấy home directory của 1 user, tương thích cả macOS (dscl) và Linux (getent).
# Dùng cho bước [Tuỳ chọn] tạo thêm remote user ở cuối script.
get_home_dir() {
  local u="$1"
  if [[ "$OS" == "Darwin" ]]; then
    dscl . -read "/Users/$u" NFSHomeDirectory 2>/dev/null | awk '{print $2}'
  else
    getent passwd "$u" 2>/dev/null | cut -d: -f6
  fi
}

echo ""
echo "==> [1/5] Kiểm tra / cài autossh"
ensure_pkg "autossh" "command -v autossh" "autossh" || { echo "Cài autossh thủ công rồi chạy lại." >&2; exit 1; }
AUTOSSH_BIN="$(command -v autossh)"

echo ""
echo "==> [2/5] Kiểm tra các port đích trên máy này (local_port) đã sẵn sàng chưa"
# Đây chính là lỗi hay gặp nhất trên thực tế: tunnel kết nối lên VPS OK, nhưng
# forward về máy local thất bại vì chưa có gì chạy ở local_port (vd sshd chưa cài
# trên WSL/máy mới) -> lỗi "connect_to localhost port X: failed" chỉ hiện trong
# log service, rất khó debug. Kiểm tra + tự cài trước khi tạo tunnel.
# Gom lại mọi port map chưa xác nhận sẵn sàng để in bảng tổng kết TO ở cuối
# script — cảnh báo lẻ giữa log rất dễ bị bỏ sót (đã gặp thật: root cause 1 lần
# debug rất lâu chỉ vì cảnh báo này trôi mất giữa hàng chục dòng log khác).
UNVERIFIED_PORTS=()
for pm in "${PORT_MAPS[@]}"; do
  local_p="${pm#*:}"
  if port_is_listening "$local_p"; then
    echo "    [port] $local_p: đã có service lắng nghe -> BỎ QUA (không cần cài gì)."
    continue
  fi

  if [[ "$local_p" == "22" ]]; then
    echo "    [port] 22: CHƯA có gì lắng nghe — cần sshd để nhận SSH vào máy này."
    if [[ "$OS" == "Darwin" ]]; then
      REMOTE_LOGIN_STATUS="$($SUDO systemsetup -getremotelogin 2>/dev/null | awk -F': ' '{print $2}')"
      if [[ "$REMOTE_LOGIN_STATUS" == "On" ]]; then
        echo "    [macOS] Remote Login: đã bật sẵn -> BỎ QUA."
      else
        echo "    [macOS] Remote Login: đang TẮT -> đang bật (System Settings > Sharing)..."
        $SUDO systemsetup -setremotelogin on
        echo "    [macOS] Remote Login: đã bật."
      fi
    else
      ensure_pkg "openssh-server (sshd)" "sshd_really_installed" "openssh-server" \
        || install_pkg openssh
      # QUAN TRỌNG: chỉ có "systemctl" trong PATH không có nghĩa là systemd đang
      # thực sự chạy làm init (PID 1) — container/WSL1/chroot thường có binary
      # nhưng gọi vào sẽ lỗi "Host is down". Phải verify bằng port_is_listening
      # thật sự rồi mới fallback sang "service", không được tin suông vào việc
      # binary tồn tại (đã tái hiện được lỗi này bằng test thật).
      SSHD_STARTED=0
      if command -v systemctl &>/dev/null; then
        echo "    [service] đang thử bật sshd qua systemctl..."
        ENABLE_ERR="$( { $SUDO systemctl enable --now ssh || $SUDO systemctl enable --now sshd; } 2>&1)" || true
        if echo "$ENABLE_ERR" | grep -qi "could not be found"; then
          echo "    [service] systemctl báo KHÔNG tìm thấy unit ssh/sshd -> gói openssh-server" \
               "thực ra chưa cài xong dù bước kiểm tra trước đó tưởng đã có. Đang cài lại..."
          install_pkg openssh-server || install_pkg openssh || true
          $SUDO systemctl daemon-reload 2>/dev/null || true
          $SUDO systemctl enable --now ssh 2>/dev/null || $SUDO systemctl enable --now sshd 2>/dev/null || true
        fi
        sleep 1
        if port_is_listening "22"; then
          SSHD_STARTED=1
          echo "    [service] systemctl: THÀNH CÔNG (port 22 đã lắng nghe)."
        else
          echo "    [service] systemctl: không có tác dụng thật (thường do container/WSL1/chroot" \
               "không có systemd PID 1 thật) -> fallback sang 'service'."
        fi
      fi
      if [[ $SSHD_STARTED -eq 0 ]]; then
        echo "    [service] đang thử bật sshd qua 'service'..."
        $SUDO service ssh start 2>/dev/null || $SUDO service sshd start 2>/dev/null || true
      fi
    fi
    sleep 1
    if port_is_listening "22"; then
      echo "    [port] 22: đã lắng nghe sau khi cài/bật sshd -> OK."
    else
      echo "    [port] 22: CẢNH BÁO — vẫn CHƯA lắng nghe sau khi cố cài/bật sshd." >&2
      echo "    Tunnel vẫn sẽ được tạo, nhưng forward tới port này sẽ lỗi cho đến khi bạn tự kiểm tra sshd." >&2
      UNVERIFIED_PORTS+=("$pm (sshd không tự bật được)")
    fi
  else
    echo "    [port] $local_p: CẢNH BÁO — chưa có gì lắng nghe trên máy này." >&2
    echo "    Đây là port của ứng dụng riêng của bạn — script không biết cách tự chạy hộ." >&2
    echo "    Tunnel vẫn được tạo, nhưng sẽ lỗi cho tới khi bạn tự chạy service ở port $local_p." >&2
    UNVERIFIED_PORTS+=("$pm (chưa có gì lắng nghe ở local_port $local_p)")
  fi
done

echo "==> [3/5] Test kết nối SSH tới VPS trước khi tạo service nền"
# Không dùng -N ở đây: -N giữ session mở vô thời hạn để chờ forward, nếu không có
# request forward nào thì lệnh sẽ treo mãi. Ta chỉ cần biết AUTHENTICATION có qua không.
set +e
ssh -n -i "$KEY_PATH" -o BatchMode=yes -o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new \
  "$TUNNEL_USER@$VPS_IP" true 2>/tmp/ssh_test_err.log
SSH_TEST_EXIT=$?
set -e

if [[ $SSH_TEST_EXIT -eq 255 ]]; then
  echo "Cảnh báo: không kết nối/xác thực SSH được tới $TUNNEL_USER@$VPS_IP." >&2
  echo "Chi tiết lỗi:" >&2
  cat /tmp/ssh_test_err.log >&2
  echo "Kiểm tra lại: user đã được tạo trên VPS chưa, public key đã đúng chưa." >&2
  read -r -p "Vẫn tiếp tục cài service nền? (y/N) " ans
  [[ "$ans" =~ ^[Yy]$ ]] || exit 1
else
  # Exit code khác 0 (nhưng không phải 255) là bình thường: user tunnel bị ép
  # ForceCommand /usr/sbin/nologin nên không chạy lệnh "true" được, nhưng auth đã OK.
  echo "    Kết nối SSH tới VPS OK (xác thực thành công)."
fi

echo "==> [4/5] Tạo ~/.ssh/config entry để truy cập máy local qua VPS"
SSH_CONFIG="$HOME/.ssh/config"
touch "$SSH_CONFIG"
chmod 600 "$SSH_CONFIG"
MARKER_START="# >>> vps-tunnel: $VPS_IP >>>"
MARKER_END="# <<< vps-tunnel: $VPS_IP <<<"

# Luôn xoá block cũ (nếu có) rồi ghi lại mới — tránh config bị lỗi thời khi chạy
# lại script với port map khác (vd đổi remote_port cho SSH từ 2222 sang 2200).
if grep -qF "$MARKER_START" "$SSH_CONFIG" 2>/dev/null; then
  sed -i.bak "/^$(printf '%s' "$MARKER_START" | sed 's/[.[\*^$/]/\\&/g')\$/,/^$(printf '%s' "$MARKER_END" | sed 's/[.[\*^$/]/\\&/g')\$/d" "$SSH_CONFIG"
  rm -f "${SSH_CONFIG}.bak"
fi

remote_ssh_port=""
for pm in "${PORT_MAPS[@]}"; do
  if [[ "${pm#*:}" == "22" ]]; then
    remote_ssh_port="${pm%%:*}"
    break
  fi
done
AUTHORIZE_SELF=1
if [[ -n "$remote_ssh_port" && $IS_ROOT -eq 1 ]]; then
  # Đang chạy bằng root: authorize key vào /root/.ssh/authorized_keys nghĩa là
  # MỞ QUYỀN SSH THẲNG VÀO ROOT qua tunnel — gần như luôn KHÔNG phải điều mong
  # muốn khi dùng root chỉ để provisioning (tạo user + key cho người khác).
  # Mặc định là KHÔNG, phải chủ động chọn 'y' mới mở.
  echo ""
  echo "    Đang chạy bằng root. Bạn có muốn authorize key này để SSH THẲNG VÀO ROOT"
  echo "    qua tunnel không? (thường KHÔNG cần: người dùng thật sẽ SSH vào các user"
  echo "    riêng tạo ở bước cuối script, an toàn hơn nhiều so với login thẳng root)"
  read -r -p "    Mở SSH vào root? (y/N): " ans
  if [[ "$ans" =~ ^[Yy]$ ]]; then
    AUTHORIZE_SELF=1
  else
    AUTHORIZE_SELF=0
    echo "    -> BỎ QUA (không mở SSH vào root). Tạo user riêng ở bước cuối script để dùng."
  fi
fi

if [[ -n "$remote_ssh_port" && $AUTHORIZE_SELF -eq 1 ]]; then
  # Key vps_tunnel mới chỉ được VPS chấp nhận (để xác thực tunnel). Muốn "ssh home"
  # đăng nhập được thẳng vào MÁY NÀY mà không hỏi mật khẩu, chính máy này cũng phải
  # tự authorize key đó cho user hiện tại — nếu không, "hop cuối" (VPS -> máy này)
  # sẽ rơi về password auth như bình thường (đây chính là lỗi vừa gặp).
  echo "    Đang authorize key '$KEY_PATH' để login thẳng vào máy này (user $USER)..."
  mkdir -p "$HOME/.ssh"
  chmod 700 "$HOME/.ssh"
  touch "$HOME/.ssh/authorized_keys"
  chmod 600 "$HOME/.ssh/authorized_keys"
  if ! grep -qF "$(cat "$KEY_PATH.pub")" "$HOME/.ssh/authorized_keys" 2>/dev/null; then
    cat "$KEY_PATH.pub" >> "$HOME/.ssh/authorized_keys"
    echo "    Đã thêm key vào $HOME/.ssh/authorized_keys -> 'ssh home' sẽ không hỏi mật khẩu nữa."
  else
    echo "    Key đã có sẵn trong $HOME/.ssh/authorized_keys, bỏ qua."
  fi
fi

# Ghi ~/.ssh/config SAU khi đã biết có authorize user hiện tại hay không: nếu
# không authorize (vd chạy bằng root và đã chọn KHÔNG mở SSH vào root) thì ghi
# Host "home" ra là vô nghĩa — nó sẽ trỏ tới 1 tài khoản không đăng nhập được,
# chỉ gây hiểu nhầm lúc debug.
{
  echo ""
  echo "$MARKER_START"
  echo "Host vps-jump"
  echo "    HostName $VPS_IP"
  echo "    User $TUNNEL_USER"
  echo "    IdentityFile $KEY_PATH"
  if [[ -n "$remote_ssh_port" && $AUTHORIZE_SELF -eq 1 ]]; then
    echo ""
    echo "Host home"
    echo "    HostName localhost"
    echo "    Port $remote_ssh_port"
    echo "    User $USER"
    echo "    ProxyJump vps-jump"
    echo "    IdentityFile $KEY_PATH"
  fi
  echo "$MARKER_END"
} >> "$SSH_CONFIG"
echo "    Đã ghi Host 'vps-jump'$( [[ -n "$remote_ssh_port" && $AUTHORIZE_SELF -eq 1 ]] && echo " và 'home'" ) vào $SSH_CONFIG"

R_ARGS_SH=()
for pm in "${PORT_MAPS[@]}"; do
  remote="${pm%%:*}"
  local_p="${pm#*:}"
  R_ARGS_SH+=("-R" "127.0.0.1:${remote}:localhost:${local_p}")
done

if [[ $IS_ROOT -eq 1 ]]; then
  # ==========================================================================
  # CHẠY BẰNG ROOT -> service HỆ THỐNG (không phải service theo user).
  # Lý do không dùng systemd --user/LaunchAgent ở đây: cả 2 cơ chế đó gắn với
  # PHIÊN ĐĂNG NHẬP của 1 user. Root khi provisioning (qua sudo/su/SSH) thường
  # không có phiên dbus/graphical thật -> `systemctl --user` báo "Failed to
  # connect to bus", còn LaunchAgent của root thì không bao giờ được load vì
  # root không "đăng nhập" vào giao diện macOS. Service hệ thống chạy từ lúc
  # boot, không phụ thuộc ai đăng nhập — đúng với mô hình "root setup sẵn, người
  # dùng thật chỉ SSH vào user riêng của họ".
  # ==========================================================================
  if [[ "$OS" == "Darwin" ]]; then
    echo "==> [5/5] Tạo LaunchDaemon (macOS, chạy bằng root) để tunnel tự chạy nền + tự reconnect"
    PLIST_LABEL="com.vpstunnel.$VPS_IP"
    PLIST_PATH="/Library/LaunchDaemons/${PLIST_LABEL}.plist"

    R_ARGS_XML=()
    for a in "${R_ARGS_SH[@]}"; do
      R_ARGS_XML+=("<string>${a}</string>")
    done
    R_ARGS_XML_STR=$(printf '%s\n            ' "${R_ARGS_XML[@]}")

    cat > "$PLIST_PATH" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${PLIST_LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>${AUTOSSH_BIN}</string>
        <string>-M</string>
        <string>0</string>
        <string>-N</string>
        <string>-o</string>
        <string>ServerAliveInterval=30</string>
        <string>-o</string>
        <string>ServerAliveCountMax=3</string>
        <string>-o</string>
        <string>ExitOnForwardFailure=yes</string>
        <string>-o</string>
        <string>StrictHostKeyChecking=accept-new</string>
        <string>-i</string>
        <string>${KEY_PATH}</string>
        ${R_ARGS_XML_STR}<string>${TUNNEL_USER}@${VPS_IP}</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>/var/log/${PLIST_LABEL}.log</string>
    <key>StandardErrorPath</key>
    <string>/var/log/${PLIST_LABEL}.err.log</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>AUTOSSH_GATETIME</key>
        <string>0</string>
    </dict>
</dict>
</plist>
EOF
    # LaunchDaemon bắt buộc thuộc root:wheel và không được ghi bởi user khác,
    # nếu sai quyền launchd sẽ từ chối load mà không báo lỗi rõ ràng.
    chown root:wheel "$PLIST_PATH"
    chmod 644 "$PLIST_PATH"

    launchctl unload "$PLIST_PATH" 2>/dev/null || true
    launchctl load -w "$PLIST_PATH"
    sleep 2

    echo ""
    if launchctl list "$PLIST_LABEL" &>/dev/null; then
      echo "✔ LaunchDaemon đã load. Tunnel đang chạy nền (chạy từ lúc boot, không cần ai đăng nhập): $PLIST_LABEL"
    else
      echo "✘ LaunchDaemon KHÔNG load được. Xem log:" >&2
      tail -n 20 "/var/log/${PLIST_LABEL}.err.log" 2>/dev/null >&2 || true
      exit 1
    fi
    echo "  - Log: /var/log/${PLIST_LABEL}.log và /var/log/${PLIST_LABEL}.err.log"
    echo "  - Port map: ${PORT_MAPS[*]}"
    echo "  - Dừng tunnel:   launchctl unload $PLIST_PATH"
    echo "  - Chạy lại:      launchctl load -w $PLIST_PATH"

  else
    echo "==> [5/5] Tạo systemd system service (Linux, chạy bằng root) để tunnel tự chạy nền + tự reconnect"

    if ! command -v systemctl &>/dev/null; then
      echo "Lỗi: không có 'systemctl' trên máy này, không thể tạo service nền theo cách chuẩn." >&2
      echo "Chạy tunnel thủ công (không tự sống sót qua reboot):" >&2
      echo "  nohup ${AUTOSSH_BIN} -M 0 -N -o ServerAliveInterval=30 -i ${KEY_PATH} ${R_ARGS_SH[*]} ${TUNNEL_USER}@${VPS_IP} >/tmp/vpstunnel.log 2>&1 &" >&2
      exit 1
    fi

    SERVICE_SUFFIX="$(echo "$VPS_IP" | tr -c 'A-Za-z0-9' '-')"
    SERVICE_NAME="vpstunnel-${SERVICE_SUFFIX}.service"
    SERVICE_PATH="/etc/systemd/system/$SERVICE_NAME"

    EXEC_START="${AUTOSSH_BIN} -M 0 -N -o ServerAliveInterval=30 -o ServerAliveCountMax=3 -o ExitOnForwardFailure=yes -o StrictHostKeyChecking=accept-new -i ${KEY_PATH} ${R_ARGS_SH[*]} ${TUNNEL_USER}@${VPS_IP}"

    cat > "$SERVICE_PATH" <<EOF
[Unit]
Description=SSH reverse tunnel to ${VPS_IP}
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=0

[Service]
Environment=AUTOSSH_GATETIME=0
ExecStart=${EXEC_START}
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable "$SERVICE_NAME"
    # Dùng restart (không phải "enable --now"): nếu service đã tồn tại từ lần chạy
    # trước với cấu hình cũ, "enable --now" không đảm bảo áp dụng ExecStart mới.
    systemctl restart "$SERVICE_NAME"

    sleep 2
    echo ""
    if systemctl is-active --quiet "$SERVICE_NAME"; then
      echo "✔ Service đang chạy (active). Tunnel chạy nền từ lúc boot, không cần ai đăng nhập: $SERVICE_NAME"
    else
      echo "✘ Service KHÔNG active sau khi start. Xem log để biết lý do:" >&2
      systemctl status "$SERVICE_NAME" --no-pager >&2 || true
      journalctl -u "$SERVICE_NAME" -n 20 --no-pager >&2 || true
      exit 1
    fi
    echo "  - Xem log:       journalctl -u $SERVICE_NAME -f"
    echo "  - Trạng thái:    systemctl status $SERVICE_NAME"
    echo "  - Port map: ${PORT_MAPS[*]}"
    echo "  - Dừng tunnel:   systemctl stop $SERVICE_NAME"
    echo "  - Chạy lại:      systemctl start $SERVICE_NAME"
  fi
  echo ""
  echo "  LƯU Ý: máy local không thể tự kiểm chứng port đã bind trên VPS hay chưa."
  echo "  Kiểm tra trên VPS: sudo ss -tlnp | grep -E '$(echo "${PORT_MAPS[@]}" | tr ' ' '\n' | cut -d: -f1 | paste -sd'|')'"

elif [[ "$OS" == "Darwin" ]]; then
  echo "==> [5/5] Tạo LaunchAgent (macOS) để tunnel tự chạy nền + tự reconnect"
  PLIST_LABEL="com.$USER.vpstunnel.$VPS_IP"
  PLIST_PATH="$HOME/Library/LaunchAgents/${PLIST_LABEL}.plist"

  R_ARGS_XML=()
  for a in "${R_ARGS_SH[@]}"; do
    R_ARGS_XML+=("<string>${a}</string>")
  done
  R_ARGS_XML_STR=$(printf '%s\n            ' "${R_ARGS_XML[@]}")

  mkdir -p "$HOME/Library/LaunchAgents"
  cat > "$PLIST_PATH" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${PLIST_LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>${AUTOSSH_BIN}</string>
        <string>-M</string>
        <string>0</string>
        <string>-N</string>
        <string>-o</string>
        <string>ServerAliveInterval=30</string>
        <string>-o</string>
        <string>ServerAliveCountMax=3</string>
        <string>-o</string>
        <string>ExitOnForwardFailure=yes</string>
        <string>-o</string>
        <string>StrictHostKeyChecking=accept-new</string>
        <string>-i</string>
        <string>${KEY_PATH}</string>
        ${R_ARGS_XML_STR}<string>${TUNNEL_USER}@${VPS_IP}</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>/tmp/${PLIST_LABEL}.log</string>
    <key>StandardErrorPath</key>
    <string>/tmp/${PLIST_LABEL}.err.log</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>AUTOSSH_GATETIME</key>
        <string>0</string>
    </dict>
</dict>
</plist>
EOF

  launchctl unload "$PLIST_PATH" 2>/dev/null || true
  launchctl load -w "$PLIST_PATH"
  sleep 2

  echo ""
  if launchctl list "$PLIST_LABEL" &>/dev/null; then
    echo "✔ LaunchAgent đã load. Tunnel đang chạy nền: $PLIST_LABEL"
  else
    echo "✘ LaunchAgent KHÔNG load được. Xem log:" >&2
    tail -n 20 "/tmp/${PLIST_LABEL}.err.log" 2>/dev/null >&2 || true
    exit 1
  fi
  echo "  - Log: /tmp/${PLIST_LABEL}.log và /tmp/${PLIST_LABEL}.err.log"
  echo "  - Port map: ${PORT_MAPS[*]}"
  echo "  - Dừng tunnel:   launchctl unload $PLIST_PATH"
  echo "  - Chạy lại:      launchctl load -w $PLIST_PATH"
  echo ""
  echo "  LƯU Ý: máy local không thể tự kiểm chứng port đã bind trên VPS hay chưa."
  echo "  Kiểm tra trên VPS: sudo ss -tlnp | grep -E '$(echo "${PORT_MAPS[@]}" | tr ' ' '\n' | cut -d: -f1 | paste -sd'|')'"

else
  echo "==> [5/5] Tạo systemd --user service (Linux) để tunnel tự chạy nền + tự reconnect"

  if ! command -v systemctl &>/dev/null; then
    echo "Lỗi: không có 'systemctl' trên máy này, không thể tạo service nền theo cách chuẩn." >&2
    echo "Chạy tunnel thủ công (không tự sống sót qua reboot):" >&2
    echo "  nohup ${AUTOSSH_BIN} -M 0 -N -o ServerAliveInterval=30 -i ${KEY_PATH} ${R_ARGS_SH[*]} ${TUNNEL_USER}@${VPS_IP} >/tmp/vpstunnel.log 2>&1 &" >&2
    exit 1
  fi

  # Bật linger TRƯỚC khi start service: nếu không, service có thể bị systemd tắt
  # ngay khi phiên đăng nhập hiện tại kết thúc (logout/đóng SSH session).
  CURRENT_LINGER="$(loginctl show-user "$USER" -p Linger --value 2>/dev/null || echo "")"
  if [[ "$CURRENT_LINGER" != "yes" ]]; then
    if loginctl enable-linger "$USER" 2>/dev/null; then
      echo "    Đã bật linger cho user $USER."
    elif $SUDO loginctl enable-linger "$USER" 2>/dev/null; then
      echo "    Đã bật linger cho user $USER (qua sudo)."
    else
      echo "    Cảnh báo: KHÔNG bật được linger. Service có thể bị dừng khi bạn logout." >&2
      echo "    Chạy thủ công: sudo loginctl enable-linger $USER" >&2
    fi
  else
    echo "    Linger đã bật sẵn cho user $USER."
  fi

  # Kiểm tra systemd --user session có thực sự dùng được không (cần XDG_RUNTIME_DIR/dbus).
  if ! systemctl --user show-environment &>/dev/null; then
    echo "" >&2
    echo "LỖI: 'systemctl --user' không kết nối được (thiếu phiên người dùng systemd/dbus)." >&2
    echo "Thường gặp khi chạy qua sudo/su thay vì đăng nhập trực tiếp bằng chính user này." >&2
    echo "Thử: export XDG_RUNTIME_DIR=/run/user/\$(id -u) rồi chạy lại script." >&2
    exit 1
  fi

  SERVICE_SUFFIX="$(echo "$VPS_IP" | tr -c 'A-Za-z0-9' '-')"
  SERVICE_NAME="vpstunnel-${SERVICE_SUFFIX}.service"
  SYSTEMD_USER_DIR="$HOME/.config/systemd/user"
  SERVICE_PATH="$SYSTEMD_USER_DIR/$SERVICE_NAME"

  EXEC_START="${AUTOSSH_BIN} -M 0 -N -o ServerAliveInterval=30 -o ServerAliveCountMax=3 -o ExitOnForwardFailure=yes -o StrictHostKeyChecking=accept-new -i ${KEY_PATH} ${R_ARGS_SH[*]} ${TUNNEL_USER}@${VPS_IP}"

  mkdir -p "$SYSTEMD_USER_DIR"
  cat > "$SERVICE_PATH" <<EOF
[Unit]
Description=SSH reverse tunnel to ${VPS_IP}
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=0

[Service]
Environment=AUTOSSH_GATETIME=0
ExecStart=${EXEC_START}
Restart=always
RestartSec=5

[Install]
WantedBy=default.target
EOF

  systemctl --user daemon-reload
  systemctl --user enable "$SERVICE_NAME"
  # Dùng restart (không phải "enable --now"): nếu service đã tồn tại từ lần chạy
  # trước với cấu hình cũ, "enable --now" không đảm bảo áp dụng ExecStart mới.
  systemctl --user restart "$SERVICE_NAME"

  sleep 2
  echo ""
  if systemctl --user is-active --quiet "$SERVICE_NAME"; then
    echo "✔ Service đang chạy (active). Tunnel đang chạy nền qua systemd: $SERVICE_NAME"
  else
    echo "✘ Service KHÔNG active sau khi start. Xem log để biết lý do:" >&2
    systemctl --user status "$SERVICE_NAME" --no-pager >&2 || true
    journalctl --user -u "$SERVICE_NAME" -n 20 --no-pager >&2 || true
    exit 1
  fi
  echo "  - Xem log:       journalctl --user -u $SERVICE_NAME -f"
  echo "  - Trạng thái:    systemctl --user status $SERVICE_NAME"
  echo "  - Port map: ${PORT_MAPS[*]}"
  echo "  - Dừng tunnel:   systemctl --user stop $SERVICE_NAME"
  echo "  - Chạy lại:      systemctl --user start $SERVICE_NAME"
  echo ""
  echo "  LƯU Ý: máy local không thể tự kiểm chứng port đã bind trên VPS hay chưa."
  echo "  Kiểm tra trên VPS: sudo ss -tlnp | grep -E '$(echo "${PORT_MAPS[@]}" | tr ' ' '\n' | cut -d: -f1 | paste -sd'|')'"
fi

if [[ -n "$remote_ssh_port" && $AUTHORIZE_SELF -eq 1 ]]; then
  echo "  - SSH vào máy này từ bất kỳ đâu (có ~/.ssh/config này): ssh home"
elif [[ -n "$remote_ssh_port" ]]; then
  echo "  - Chưa có tài khoản nào SSH vào máy này được qua tunnel — tạo ở bước cuối script."
fi

if [[ ${#UNVERIFIED_PORTS[@]} -gt 0 ]]; then
  echo ""
  echo "########################################################################"
  echo "##  CẢNH BÁO: ${#UNVERIFIED_PORTS[@]} port map CHƯA XÁC NHẬN sẵn sàng — tunnel sẽ LỖI    ##"
  echo "########################################################################"
  for item in "${UNVERIFIED_PORTS[@]}"; do
    echo "  - $item"
  done
  echo ""
  echo "  Port map là remote_port:local_port. Lỗi hay gặp nhất: gõ nhầm"
  echo "  local_port TRÙNG remote_port thay vì trỏ đúng port thật đang chạy trên"
  echo "  máy này (vd muốn SSH vào máy này thì local_port phải là 22, KHÔNG phải"
  echo "  trùng với remote_port đã chọn cho port đó trên VPS)."
  echo "  Kiểm tra lại port map đã nhập ở trên, sửa cho đúng rồi chạy lại script."
  echo "########################################################################"
fi

# ============================================================================
# [Tuỳ chọn] Thêm remote user khác trên máy này — để nhiều người khác nhau
# cùng SSH vào máy này bằng tài khoản + key riêng của từng người, thay vì dùng
# chung 1 tài khoản. Mỗi user tạo ra: full shell (dùng máy bình thường qua SSH)
# nhưng KHÔNG có password — chỉ đăng nhập được bằng SSH key riêng, giống cách
# vps_setup.sh tạo user tunnel-only trên VPS (nhưng ở đây có shell vì mục đích
# là để dùng máy, không phải chỉ tunnel).
#
# Tận dụng lại $VPS_IP/$TUNNEL_USER/$remote_ssh_port đã hỏi ở phần setup tunnel
# phía trên — không hỏi lại các thông tin này.
# ============================================================================
add_remote_user() {
  echo ""
  read -r -p "Tên user mới muốn tạo: " NEW_USERNAME
  if ! [[ "$NEW_USERNAME" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
    echo "Lỗi: tên user không hợp lệ (chỉ chữ thường, số, '_', '-', bắt đầu bằng chữ hoặc '_')." >&2
    return 1
  fi
  if [[ "$NEW_USERNAME" == "root" ]]; then
    echo "Lỗi: không tạo user 'root' bằng bước này." >&2
    return 1
  fi

  local new_shell
  if [[ "$OS" == "Darwin" ]]; then
    new_shell="/bin/zsh"; [[ -x "$new_shell" ]] || new_shell="/bin/bash"
  else
    new_shell="/bin/bash"; [[ -x "$new_shell" ]] || new_shell="/bin/sh"
  fi

  echo "    Tạo user '$NEW_USERNAME' (full shell, KHÔNG đặt password — chỉ SSH key mới đăng nhập được)..."
  if id "$NEW_USERNAME" &>/dev/null; then
    echo "    User $NEW_USERNAME đã tồn tại, bỏ qua bước tạo user (giữ nguyên password/cấu hình hiện có)."
  else
    if [[ "$OS" == "Darwin" ]]; then
      $SUDO sysadminctl -addUser "$NEW_USERNAME" -fullName "$NEW_USERNAME" -password - -home "/Users/$NEW_USERNAME" -shell "$new_shell"
      # sysadminctl chạy bất đồng bộ — đợi tới khi user thực sự xuất hiện rồi mới đi tiếp.
      for _ in $(seq 1 10); do id "$NEW_USERNAME" &>/dev/null && break; sleep 1; done
      $SUDO createhomedir -c -u "$NEW_USERNAME" &>/dev/null || true
    else
      $SUDO useradd -m -s "$new_shell" "$NEW_USERNAME"
      $SUDO usermod -L "$NEW_USERNAME" 2>/dev/null || $SUDO passwd -l "$NEW_USERNAME" 2>/dev/null \
        || echo "    Cảnh báo: không khoá được password, hãy tự kiểm tra thủ công." >&2
    fi
    if ! id "$NEW_USERNAME" &>/dev/null; then
      echo "Lỗi: tạo user '$NEW_USERNAME' thất bại." >&2
      return 1
    fi
    echo "    Đã tạo user $NEW_USERNAME."
  fi

  if [[ "$OS" == "Darwin" ]]; then
    if $SUDO dscl . -read /Groups/com.apple.access_ssh &>/dev/null; then
      echo "    Remote Login đang giới hạn theo group 'com.apple.access_ssh' -> thêm '$NEW_USERNAME' vào group này."
      $SUDO dseditgroup -o edit -a "$NEW_USERNAME" -t user com.apple.access_ssh
    fi
  fi

  local new_key_default="$HOME/.ssh/remote_${NEW_USERNAME}"
  read -r -p "Đường dẫn lưu keypair riêng cho '$NEW_USERNAME' [$new_key_default]: " NEW_KEY_PATH
  NEW_KEY_PATH="${NEW_KEY_PATH:-$new_key_default}"
  if [[ "$NEW_KEY_PATH" == *' '* ]]; then
    echo "Lỗi: đường dẫn key không được chứa khoảng trắng." >&2
    return 1
  fi
  if [[ -f "$NEW_KEY_PATH" ]]; then
    echo "    Đã có key tại $NEW_KEY_PATH, dùng lại key này."
  else
    mkdir -p "$(dirname "$NEW_KEY_PATH")"
    ssh-keygen -t ed25519 -f "$NEW_KEY_PATH" -N "" -C "remote-$NEW_USERNAME-$(date +%Y%m%d)"
    echo "    Đã tạo keypair: $NEW_KEY_PATH (private) / $NEW_KEY_PATH.pub (public)"
  fi

  local new_user_home new_ssh_dir new_group
  new_user_home="$(get_home_dir "$NEW_USERNAME")"
  if [[ -z "$new_user_home" || ! -d "$new_user_home" ]]; then
    echo "Lỗi: không tìm thấy home directory của user '$NEW_USERNAME'." >&2
    return 1
  fi
  new_ssh_dir="$new_user_home/.ssh"
  $SUDO mkdir -p "$new_ssh_dir"
  $SUDO touch "$new_ssh_dir/authorized_keys"
  if ! $SUDO grep -qF "$(cat "$NEW_KEY_PATH.pub")" "$new_ssh_dir/authorized_keys" 2>/dev/null; then
    cat "$NEW_KEY_PATH.pub" | $SUDO tee -a "$new_ssh_dir/authorized_keys" >/dev/null
    echo "    Đã thêm public key vào $new_ssh_dir/authorized_keys."
  else
    echo "    Key đã có sẵn trong authorized_keys, bỏ qua (giữ nguyên các key khác đã có)."
  fi
  new_group="$(id -gn "$NEW_USERNAME")"
  $SUDO chown -R "$NEW_USERNAME:$new_group" "$new_ssh_dir"
  $SUDO chmod 700 "$new_ssh_dir"
  $SUDO chmod 600 "$new_ssh_dir/authorized_keys"

  echo ""
  echo "    [Hop cuối] Đang tự kiểm tra: '$NEW_USERNAME' đăng nhập được vào MÁY NÀY bằng key mới chưa..."
  set +e
  ssh -n -i "$NEW_KEY_PATH" -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new \
    -p 22 "${NEW_USERNAME}@127.0.0.1" true 2>/tmp/ssh_newuser_hop2_err.log
  local hop2_exit=$?
  set -e
  if [[ $hop2_exit -eq 0 ]]; then
    echo "    OK — hop cuối (vào đúng user trên máy này) đã hoạt động, không hỏi password."
  else
    echo "    CẢNH BÁO: hop cuối CHƯA hoạt động (exit $hop2_exit). Chi tiết lỗi:" >&2
    cat /tmp/ssh_newuser_hop2_err.log >&2
    echo "    User vẫn được tạo, nhưng cần tự debug trước khi bàn giao cho '$NEW_USERNAME'." >&2
  fi

  echo ""
  echo "------------------------------------------------------------------------"
  echo "  User '$NEW_USERNAME' đã tạo xong (full shell, không password)."
  echo "------------------------------------------------------------------------"
  echo "  Private key vừa sinh: $NEW_KEY_PATH"
  echo ""
  echo "  QUAN TRỌNG 1: nếu '$NEW_USERNAME' là NGƯỜI KHÁC (không phải bạn), private"
  echo "  key này phải được chuyển cho họ qua kênh an toàn (scp/sftp) rồi XOÁ khỏi"
  echo "  máy này — không nên để private key tồn tại ở 2 nơi lâu dài:"
  echo "    scp $NEW_KEY_PATH <họ>@<máy_của_họ>:~/.ssh/"
  echo "    shred -u $NEW_KEY_PATH 2>/dev/null || rm -f $NEW_KEY_PATH   # chạy SAU khi họ đã nhận key"
  echo ""

  if [[ -z "$remote_ssh_port" ]]; then
    echo "  Lần chạy này không forward port 22 lên VPS (không có local_port=22 trong"
    echo "  port map) nên '$NEW_USERNAME' CHƯA thể SSH vào máy này từ xa qua tunnel —"
    echo "  chỉ mới SSH được khi đang ở cùng mạng local (test hop cuối ở trên)."
    echo "  Chạy lại local_setup.sh và thêm 1 port map dạng <remote_port>:22 để mở hop đầu." >&2
    echo "------------------------------------------------------------------------"
    return 0
  fi

  echo "  QUAN TRỌNG 2: key này mới chỉ được MÁY NÀY chấp nhận (hop cuối). Để"
  echo "  '$NEW_USERNAME' tự nhảy qua VPS được (hop đầu, ProxyJump vào '$TUNNEL_USER'),"
  echo "  key này còn phải được ĐĂNG KÝ THÊM trên VPS. Sang VPS, chạy lại vps_setup.sh,"
  echo "  nhập ĐÚNG cùng user '$TUNNEL_USER' và ĐÚNG cùng danh sách port như lần trước"
  echo "  (vps_setup.sh ghi đè toàn bộ port list mỗi lần chạy — nhập thiếu port cũ sẽ"
  echo "  vô tình bịt mất port đó), rồi dán public key dưới đây khi được hỏi"
  echo "  (vps_setup.sh tự APPEND, không xoá key của người khác đã có sẵn):"
  echo ""
  cat "$NEW_KEY_PATH.pub"
  echo ""
  read -r -p "  Đã dán public key ở trên vào vps_setup.sh trên VPS xong chưa? Nhấn Enter để tự kiểm tra..." _

  echo "    [Hop đầu] Đang tự kiểm tra: key mới có nhảy qua VPS ('$TUNNEL_USER@$VPS_IP') được chưa..."
  set +e
  ssh -n -i "$NEW_KEY_PATH" -o BatchMode=yes -o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new \
    "${TUNNEL_USER}@${VPS_IP}" true 2>/tmp/ssh_newuser_hop1_err.log
  local hop1_exit=$?
  set -e
  if [[ $hop1_exit -eq 255 ]]; then
    echo "    CẢNH BÁO: CHƯA nhảy qua VPS được bằng key mới (auth thất bại). Chi tiết lỗi:" >&2
    cat /tmp/ssh_newuser_hop1_err.log >&2
    echo "    Kiểm tra lại: đã dán ĐÚNG public key ở trên vào vps_setup.sh, đúng user '$TUNNEL_USER' chưa." >&2
    echo "    (Có thể dán lại và chạy lại vps_setup.sh bất cứ lúc nào — không xoá key khác đã có.)" >&2
  else
    # Exit code khác 0 (nhưng không phải 255) là bình thường: $TUNNEL_USER bị ép
    # ForceCommand /usr/sbin/nologin nên không chạy lệnh "true" được, nhưng auth đã OK.
    echo "    OK — hop đầu (nhảy qua VPS) đã hoạt động."
  fi

  echo ""
  echo "  Trên máy của '$NEW_USERNAME', thêm vào ~/.ssh/config:"
  echo ""
  echo "    Host vps-jump"
  echo "        HostName $VPS_IP"
  echo "        User $TUNNEL_USER"
  echo "        IdentityFile <đường_dẫn_họ_lưu_private_key_ở_trên>"
  echo ""
  echo "    Host home-$NEW_USERNAME"
  echo "        HostName localhost"
  echo "        Port $remote_ssh_port"
  echo "        User $NEW_USERNAME"
  echo "        ProxyJump vps-jump"
  echo "        IdentityFile <đường_dẫn_họ_lưu_private_key_ở_trên>"
  echo ""
  echo "  Rồi dùng: ssh home-$NEW_USERNAME"
  echo "------------------------------------------------------------------------"
}

echo ""
read -r -p "Tạo thêm remote user khác trên máy này (để người khác SSH vào bằng tài khoản + key riêng)? (y/N): " ADD_USER_ANS
while [[ "$ADD_USER_ANS" =~ ^[Yy]$ ]]; do
  add_remote_user
  echo ""
  read -r -p "Tạo thêm 1 remote user nữa? (y/N): " ADD_USER_ANS
done
