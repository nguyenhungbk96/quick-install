#!/usr/bin/env bash
#
# local_setup.sh — Setup máy local (macOS hoặc Linux) để tự động mở SSH reverse tunnel
# lên VPS, dùng autossh + service nền để tự chạy lại khi mất mạng/khởi động máy.
#
# Service nền dùng cơ chế nào là tuỳ CHẠY BẰNG AI:
#   - user thường -> service theo user: LaunchAgent (macOS) / systemd --user (Linux)
#   - root        -> service hệ thống:  LaunchDaemon (macOS) / systemd system unit
#                    (Linux) — chạy từ lúc boot, không phụ thuộc ai đăng nhập
#
# Chạy đơn giản:
#   ./local_setup.sh          # tự dùng tài khoản hiện tại làm đích SSH
#   sudo ./local_setup.sh     # provisioning: root tạo sẵn user + key cho người khác
# Script sẽ hỏi từng bước: tạo/chọn key, IP VPS, user tunnel, các port cần forward.
#
SCRIPT_VERSION="1.14.0"

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
cat <<'GUIDE'
########################################################################
##  LỘ TRÌNH: LOCAL (tạo key) -> VPS (tạo user) -> LOCAL (mở tunnel)
########################################################################
  1. LOCAL: <<< BẠN ĐANG Ở ĐÂY. Script tạo key và in PUBLIC KEY. Copy lại,
            rồi để cửa sổ này dừng ở câu "Đã setup xong user tunnel...".
  2. VPS  : chạy vps_setup.sh, dán public key. Cuối script nó in sẵn
            IP VPS / tên user / port map để nhập ở bước 3.
  3. LOCAL: quay lại cửa sổ này, nhấn Enter, nhập các thông tin đó.
  Thêm máy khác: lặp 1-3 với key mới + remote_port mới, CÙNG tên user.
########################################################################
GUIDE
echo ""

# ============================================================================
# Hỏi 1 câu: LUÔN hiện được câu hỏi, và LUÔN đọc từ bàn phím thật.
#
# Vì sao không dùng thẳng `read -p` (2 lỗi thật đã gặp, đã tái hiện được):
#   1) bash CHỈ in prompt của `read -p` khi stdin là terminal. Nếu stdin bị lệnh
#      khác đọc mất (ssh, apt/debconf...) hoặc bị redirect, câu hỏi KHÔNG hiện ra
#      -> người dùng chỉ thấy script "đứng im", không biết nó đang chờ trả lời.
#   2) Nếu stdin đã hết (EOF), `read` trả về ngay chuỗi rỗng -> script âm thầm tự
#      chọn mặc định, người dùng không kịp trả lời gì.
# Cách làm: in câu hỏi bằng printf ra stdout (luôn nhìn thấy, vào cả file log nếu
# có tee), và đọc thẳng từ /dev/tty (bàn phím thật) nếu có — không phụ thuộc stdin.
# ============================================================================
#
# Thứ tự đọc: STDIN trước, chỉ khi STDIN đã hết (EOF) mới fallback sang /dev/tty.
# KHÔNG đọc /dev/tty trước, vì như thế sẽ làm hỏng cách chạy tự động (đưa sẵn câu
# trả lời qua pipe/heredoc): lúc đó câu trả lời nằm ở stdin, còn /dev/tty rỗng nên
# script sẽ treo vô hạn — đã tái hiện đúng lỗi này khi test bằng Docker.
ASK_REPLY=""
ask() {
  local prompt="$1" default="${2:-}"
  ASK_REPLY=""
  printf '%s' "$prompt"
  if IFS= read -r ASK_REPLY; then
    :
  elif [[ -r /dev/tty ]] && IFS= read -r ASK_REPLY < /dev/tty; then
    :
  else
    ASK_REPLY=""
    printf '\n'
  fi
  [[ -n "$ASK_REPLY" ]] || ASK_REPLY="$default"
}

# Như ask() nhưng KHÔNG hiện ký tự gõ vào (dùng cho password).
ask_secret() {
  local prompt="$1"
  ASK_REPLY=""
  printf '%s' "$prompt"
  if IFS= read -r -s ASK_REPLY; then
    :
  elif [[ -r /dev/tty ]] && IFS= read -r -s ASK_REPLY < /dev/tty; then
    :
  else
    ASK_REPLY=""
  fi
  printf '\n'
}

ask "Đường dẫn private key muốn dùng [$KEY_DEFAULT]: " "$KEY_DEFAULT"; KEY_PATH="$ASK_REPLY"
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
  ask "Tạo mới key ed25519 tại đây? (Y/n): "; ans="$ASK_REPLY"
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
ask "Đã setup xong user tunnel trên VPS (chạy vps_setup.sh) chưa? Nhấn Enter để tiếp tục..."

echo ""
ask "IP hoặc domain của VPS: "; VPS_IP="$ASK_REPLY"
while [[ -z "$VPS_IP" || "$VPS_IP" == *' '* ]]; do
  ask "IP/domain không hợp lệ hoặc trống. Nhập lại: "; VPS_IP="$ASK_REPLY"
done

ask "Tên user tunnel trên VPS [tunneluser]: " "tunneluser"; TUNNEL_USER="$ASK_REPLY"
TUNNEL_USER="${TUNNEL_USER:-tunneluser}"
if [[ "$TUNNEL_USER" == *' '* ]]; then
  echo "Lỗi: tên user không được chứa khoảng trắng." >&2
  exit 1
fi

echo ""
echo "Nhập danh sách port muốn forward, dạng remote_port:local_port, cách nhau bởi dấu cách."
echo "  remote_port : port sẽ mở trên VPS (chỉ bind localhost VPS, dùng qua SSH jump)"
echo "  local_port  : port tương ứng trên máy bạn (22 = SSH vào chính máy này)"
echo ""
echo "  QUY TẮC: remote_port phải RIÊNG cho từng máy (không trùng máy khác đang dùng chung"
echo "  VPS/user tunnel) và phải nằm trong danh sách đã khai khi chạy vps_setup.sh."
echo ""
echo "  Ví dụ:"
echo "    2201:22              -> SSH vào máy này qua port 2201 trên VPS"
echo "    2201:22 8080:3000    -> SSH (2201) + web app chạy ở port 3000 của máy này (mở ra 8080)"
echo "    2202:22              -> máy thứ hai dùng chung VPS: đổi sang 2202, KHÔNG dùng lại 2201"
echo ""
PORT_MAPS=()
for _attempt in 1 2 3; do
  ask "Port map (vd: 2201:22): "; PORT_MAPS_RAW="$ASK_REPLY"
  PORT_MAPS=()
  read -r -a PORT_MAPS <<< "$PORT_MAPS_RAW"
  PORT_MAPS_OK=1
  if [[ ${#PORT_MAPS[@]} -eq 0 ]]; then
    PORT_MAPS_OK=0
    echo "  Chưa nhập port map nào. Cần ít nhất 1 cặp, vd: 2201:22" >&2
  else
    for pm in "${PORT_MAPS[@]}"; do
      if ! [[ "$pm" =~ ^[0-9]+:[0-9]+$ ]] \
         || (( 10#${pm%%:*} < 1 || 10#${pm%%:*} > 65535 || 10#${pm#*:} < 1 || 10#${pm#*:} > 65535 )); then
        PORT_MAPS_OK=0
        echo "  '$pm' không hợp lệ — phải có dạng remote_port:local_port (số 1-65535), vd 2201:22" >&2
      fi
    done
  fi
  [[ $PORT_MAPS_OK -eq 1 ]] && break
  PORT_MAPS=()
done
if [[ ${#PORT_MAPS[@]} -eq 0 ]]; then
  echo "Lỗi: không có port map hợp lệ sau 3 lần nhập. Chạy lại script và nhập theo ví dụ ở trên." >&2
  exit 1
fi

# Port SSH THẬT của chính máy này, dùng xuyên suốt script thay cho số 22 cứng.
# Mặc định 22, nhưng KHÔNG phải lúc nào cũng vậy: trên 1 máy Windows chạy NHIỀU
# distro WSL, các distro dùng CHUNG network namespace nên chỉ 1 distro giữ được
# port 22 — những distro còn lại BẮT BUỘC cho sshd nghe port khác, nếu không
# tunnel sẽ âm thầm trỏ vào sshd của distro khác (bug thật đã gặp).
SSH_LOCAL_PORT=""
for pm in "${PORT_MAPS[@]}"; do
  if [[ "${pm#*:}" == "22" ]]; then SSH_LOCAL_PORT="22"; break; fi
done
if [[ -z "$SSH_LOCAL_PORT" ]]; then
  echo ""
  echo "Port map không có local_port 22. Nếu bạn muốn SSH vào CHÍNH MÁY NÀY qua tunnel,"
  echo "cho biết local_port nào là sshd của máy này — script sẽ tự cấu hình sshd nghe"
  echo "đúng port đó (cần thiết khi 1 máy Windows chạy nhiều distro WSL: chỉ 1 distro"
  echo "được giữ port 22, các distro khác phải dùng port riêng)."
  ask "  local_port dùng cho SSH [để trống = không SSH vào máy này]: "; SSH_LOCAL_PORT="$ASK_REPLY"
  if [[ -n "$SSH_LOCAL_PORT" ]]; then
    if ! [[ "$SSH_LOCAL_PORT" =~ ^[0-9]+$ ]] || (( SSH_LOCAL_PORT < 1 || SSH_LOCAL_PORT > 65535 )); then
      echo "Lỗi: port '$SSH_LOCAL_PORT' không hợp lệ." >&2
      exit 1
    fi
    FOUND_IN_MAP=0
    for pm in "${PORT_MAPS[@]}"; do
      [[ "${pm#*:}" == "$SSH_LOCAL_PORT" ]] && FOUND_IN_MAP=1 && break
    done
    if [[ $FOUND_IN_MAP -eq 0 ]]; then
      echo "Lỗi: '$SSH_LOCAL_PORT' không có trong port map đã nhập ($PORT_MAPS_RAW)." >&2
      echo "Thêm 1 cặp dạng <remote_port>:$SSH_LOCAL_PORT rồi chạy lại." >&2
      exit 1
    fi
    echo "    -> sshd của máy này sẽ dùng port $SSH_LOCAL_PORT."
  fi
fi

# ============================================================================
# Remote user: HỎI Ở ĐÂY (cùng cụm câu hỏi đầu script) nhưng TẠO Ở BƯỚC [3/6].
#
# Vì sao tách đôi thay vì hỏi-và-tạo luôn tại chỗ:
#   - Hỏi hết 1 lượt ở đầu -> trả lời xong là script chạy liền mạch tới cuối,
#     không bắt bạn ngồi canh để trả lời thêm giữa chừng.
#   - Nhưng việc TẠO thật phải đợi sau bước [2/6], vì ngay sau khi tạo user
#     script tự SSH thử vào chính user đó để kiểm chứng "đăng nhập được bằng
#     key, không hỏi password" — muốn thử được thì sshd phải đã cài & chạy,
#     mà đó chính là việc bước [2/6] lo.
# ============================================================================
NEW_USERNAMES=()
NEW_PASSWORDS=()
NEW_KEYPATHS=()
NEW_SUDOMODES=()   # "no" | "pass" (sudo có hỏi password) | "nopass" (NOPASSWD)

collect_remote_users() {
  local ans username password password2 keypath key_default sudo_ans nopass_ans sudomode sudo_desc
  echo ""
  echo "Ngoài tài khoản đang chạy script, có cần TẠO THÊM user riêng trên máy này để"
  echo "người khác SSH vào bằng tài khoản + key riêng của họ không? (mỗi người 1 user,"
  echo "1 key riêng -> thu hồi quyền từng người không ảnh hưởng ai khác)"
  ask "Tạo remote user? (y/N): " "n"; ans="$ASK_REPLY"

  while [[ "$ans" =~ ^[Yy]$ ]]; do
    ask "  Tên user muốn tạo: "; username="$ASK_REPLY"
    if ! [[ "$username" =~ ^[a-z_][a-z0-9_-]*$ ]] || [[ "$username" == "root" ]]; then
      echo "  Lỗi: tên user không hợp lệ (chỉ chữ thường/số/'_'/'-', bắt đầu bằng chữ hoặc '_', không dùng 'root')." >&2
      ask "  Thử lại tên khác? (y/N): " "n"; ans="$ASK_REPLY"
      continue
    fi

    echo "  Password cho '$username':"
    echo "    - Để TRỐNG (Enter luôn) = không đặt password, chỉ đăng nhập được bằng SSH key."
    echo "      An toàn nhất, và vẫn SSH vào bình thường được."
    echo "    - Đặt password nếu user đó cần chạy 'sudo', hoặc cần đăng nhập tại màn hình máy."
    ask_secret "  Password (Enter để bỏ trống): "; password="$ASK_REPLY"
    if [[ -n "$password" ]]; then
      ask_secret "  Nhập lại password: "; password2="$ASK_REPLY"
      if [[ "$password" != "$password2" ]]; then
        echo "  Lỗi: 2 lần nhập không khớp -> bỏ qua user này." >&2
        ask "  Tạo user khác? (y/N): " "n"; ans="$ASK_REPLY"
        continue
      fi
    fi

    ask "  Cho '$username' quyền sudo? (y/N): " "n"; sudo_ans="$ASK_REPLY"
    sudomode="no"
    if [[ "$sudo_ans" =~ ^[Yy]$ ]]; then
      ask "  sudo KHÔNG cần nhập password (NOPASSWD)? (y/N): " "n"; nopass_ans="$ASK_REPLY"
      if [[ "$nopass_ans" =~ ^[Yy]$ ]]; then
        sudomode="nopass"
      else
        sudomode="pass"
        # sudo có hỏi password mà tài khoản lại KHÔNG có password thì không bao giờ
        # dùng được sudo — cảnh báo ngay lúc hỏi thay vì để phát hiện lúc dùng.
        if [[ -z "$password" ]]; then
          echo "  CẢNH BÁO: '$username' không đặt password nhưng lại chọn sudo CÓ hỏi password" >&2
          echo "  -> sẽ KHÔNG bao giờ sudo được. Chọn NOPASSWD, hoặc quay lại đặt password." >&2
        fi
      fi
    fi

    key_default="$HOME/.ssh/remote_${username}"
    ask "  Đường dẫn lưu keypair riêng cho '$username' [$key_default]: " "$key_default"; keypath="$ASK_REPLY"
    keypath="${keypath:-$key_default}"
    if [[ "$keypath" == *' '* ]]; then
      echo "  Lỗi: đường dẫn key không được chứa khoảng trắng -> bỏ qua user này." >&2
      ask "  Tạo user khác? (y/N): " "n"; ans="$ASK_REPLY"
      continue
    fi

    NEW_USERNAMES+=("$username")
    NEW_PASSWORDS+=("$password")
    NEW_KEYPATHS+=("$keypath")
    NEW_SUDOMODES+=("$sudomode")
    case "$sudomode" in
      nopass) sudo_desc=", sudo KHÔNG cần password" ;;
      pass)   sudo_desc=", có sudo (hỏi password)" ;;
      *)      sudo_desc=", không sudo" ;;
    esac
    echo "  -> Đã ghi nhận '$username'$( [[ -n "$password" ]] && echo " (có password)" || echo " (không password, chỉ SSH key)" )${sudo_desc}, key: $keypath"

    ask "  Tạo thêm user nữa? (y/N): " "n"; ans="$ASK_REPLY"
  done

  if [[ ${#NEW_USERNAMES[@]} -gt 0 ]]; then
    echo "    Sẽ tạo ${#NEW_USERNAMES[@]} user ở bước [3/6] (sau khi sshd chắc chắn sẵn sàng): ${NEW_USERNAMES[*]}"
  fi
}
collect_remote_users

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
    # Bắt buộc dùng "env" chứ KHÔNG viết "$SUDO SYSTEMD_OFFLINE=1 apt-get ...":
    # bash chỉ nhận diện "VAR=value" là gán biến lúc PARSE, tức là khi nó đứng ở
    # đầu câu lệnh trong source code. Ở đây từ đầu tiên là "$SUDO", nên khi chạy
    # bằng root ($SUDO rỗng) thì sau khi expand, "SYSTEMD_OFFLINE=1" lại bị coi
    # là TÊN LỆNH -> lỗi "SYSTEMD_OFFLINE=1: command not found" và cài hụt gói.
    # (Bug thật, đã tái hiện bằng Docker khi chạy script bằng root.)
    $SUDO env SYSTEMD_OFFLINE=1 apt-get install -y "$pkg"
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
  # QUAN TRỌNG — KHÔNG được viết `... && { exec 3>&- 2>/dev/null; return 0; }`
  # như bản cũ: `exec` KHÔNG kèm lệnh sẽ áp redirect VĨNH VIỄN cho cả shell, nên
  # `2>/dev/null` ở đó nuốt TOÀN BỘ stderr của script kể từ lần đầu hàm này trả
  # về true. Mọi cảnh báo `>&2` phía sau (port chưa sẵn sàng, SSH test lỗi, tunnel
  # không bind được port...) đều biến mất không dấu vết — cực kỳ nguy hiểm với
  # script lấy "cảnh báo to, không im lặng" làm nguyên tắc. Bug thật, đã chứng
  # minh bằng test và sửa ở v1.8.0.
  # Không cần đóng fd thủ công: fd 3 mở trong subshell và tự đóng khi subshell thoát.
  if (exec 3<>"/dev/tcp/127.0.0.1/${port}") 2>/dev/null; then
    return 0
  fi
  return 1
}

# Máy này có phải WSL không. Quan trọng vì WSL2 có 1 đặc điểm rất dễ bẫy: MỌI
# distro WSL2 chạy chung trong 1 máy ảo và dùng CHUNG network namespace (chung IP,
# chung bảng port), nhưng TÁCH PID namespace (distro này không thấy tiến trình của
# distro kia). Hệ quả: chỉ 1 distro giữ được port 22, và `hostname` của mọi distro
# đều giống nhau (lấy tên máy Windows) nên không dùng để phân biệt được.
is_wsl() {
  [[ -n "${WSL_DISTRO_NAME:-}" ]] && return 0
  grep -qi microsoft /proc/sys/kernel/osrelease 2>/dev/null
}

# Port đang lắng nghe có thuộc về 1 tiến trình NHÌN THẤY ĐƯỢC từ chính máy/distro
# này không?
# Trả về false khi port có người giữ nhưng `ss` không kèm được tiến trình nào —
# dấu hiệu điển hình của WSL nhiều distro: distro KHÁC đang giữ port trong network
# namespace dùng chung, còn PID của nó thì distro này không nhìn thấy.
# Đây chính là bug thật đã gặp: script thấy "port 22 có người nghe" liền kết luận
# OK, tunnel dựng xong trỏ thẳng vào sshd của distro khác mà không cảnh báo gì.
port_owned_here() {
  local port="$1" line
  command -v ss &>/dev/null || return 0        # không có ss -> không kết luận được
  line="$($SUDO ss -tlnp 2>/dev/null | awk -v p=":$port" '$4 ~ (p "$") {print; exit}')"
  [[ -z "$line" ]] && return 0
  [[ "$line" == *"users:(("* ]]
}

# Ubuntu/Debian đời mới bật sẵn "socket activation": chính systemd (ssh.socket)
# giữ port, sshd chỉ được gọi khi có kết nối. 2 hệ quả rất khó đoán:
#   - "Port" trong /etc/ssh/sshd_config BỊ BỎ QUA (port do ssh.socket quyết định).
#   - Nếu ssh.socket không bind được port (vd port 22 đã bị distro WSL khác giữ)
#     thì ssh.service cũng chết theo: "A dependency job for ssh.service failed".
# Tắt socket activation để sshd tự bind đúng port khai trong sshd_config.
disable_ssh_socket_activation() {
  command -v systemctl &>/dev/null || return 0
  $SUDO systemctl is-enabled ssh.socket &>/dev/null || $SUDO systemctl is-active ssh.socket &>/dev/null || return 0
  echo "    [sshd] phát hiện socket activation (ssh.socket đang giữ port) -> tắt để sshd tự bind port."
  $SUDO systemctl disable --now ssh.socket 2>/dev/null || true
  $SUDO systemctl enable --now ssh.service 2>/dev/null || $SUDO systemctl enable --now sshd.service 2>/dev/null || true
}

# Đặt sshd lắng nghe đúng port mong muốn. Cần cho trường hợp 1 máy Windows chạy
# NHIỀU distro WSL: chung network namespace nên chỉ 1 distro giữ được port 22,
# các distro còn lại BẮT BUỘC phải cho sshd nghe port khác.
set_sshd_port() {
  local port="$1" cfg="/etc/ssh/sshd_config"
  [[ -f "$cfg" ]] || return 1
  if $SUDO grep -qE "^[[:space:]]*Port[[:space:]]+${port}([[:space:]]|$)" "$cfg"; then
    echo "    [sshd] sshd_config đã có 'Port $port' -> BỎ QUA."
    return 0
  fi
  $SUDO cp "$cfg" "${cfg}.bak.$(date +%Y%m%d%H%M%S)"
  $SUDO sed -i -E "s/^[[:space:]]*#?[[:space:]]*Port[[:space:]]+[0-9]+/Port ${port}/" "$cfg"
  if ! $SUDO grep -qE "^[[:space:]]*Port[[:space:]]+${port}([[:space:]]|$)" "$cfg"; then
    echo "Port ${port}" | $SUDO tee -a "$cfg" >/dev/null
  fi
  echo "    [sshd] đã đặt 'Port $port' trong sshd_config (đã backup ${cfg}.bak.*)."
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
# Cấp quyền sudo cho 1 user theo chế độ đã chọn ("pass" = sudo có hỏi password,
# "nopass" = NOPASSWD).
#
# Ghi vào DROP-IN /etc/sudoers.d/<user> chứ không sửa /etc/sudoers gốc — an toàn,
# dễ gỡ (xoá 1 file), cùng triết lý với cách vps_setup.sh xử lý sshd_config.d.
# 3 cái bẫy của sudoers đều được xử lý ở đây:
#   1) File sai cú pháp có thể làm sudo TỪ CHỐI HOẠT ĐỘNG trên cả máy -> luôn
#      validate bằng `visudo -c -f` ở file tạm TRƯỚC khi đưa vào /etc/sudoers.d/.
#   2) Quyền phải đúng 440 root:root, sai quyền thì sudo ÂM THẦM bỏ qua file.
#   3) Tên file chứa dấu chấm hoặc '~' sẽ bị sudo bỏ qua (username của script chỉ
#      cho phép [a-z0-9_-] nên luôn hợp lệ).
grant_sudo() {
  local user="$1" mode="$2" tmpf admin_group=""
  [[ "$mode" == "no" ]] && return 0

  if [[ "$OS" == "Darwin" ]]; then
    echo "    [sudo] thêm '$user' vào group 'admin' (macOS)..."
    $SUDO dseditgroup -o edit -a "$user" -t user admin 2>/dev/null || true
  else
    # Debian/Ubuntu dùng group 'sudo', RHEL/Arch/SUSE dùng 'wheel'.
    if getent group sudo &>/dev/null; then
      admin_group="sudo"
    elif getent group wheel &>/dev/null; then
      admin_group="wheel"
    fi
    if [[ -n "$admin_group" ]]; then
      $SUDO usermod -aG "$admin_group" "$user" 2>/dev/null \
        && echo "    [sudo] đã thêm '$user' vào group '$admin_group'." \
        || echo "    [sudo] CẢNH BÁO: không thêm được '$user' vào group '$admin_group'." >&2
    fi
  fi

  if [[ "$mode" == "nopass" ]]; then
    if ! command -v visudo &>/dev/null; then
      echo "    [sudo] CẢNH BÁO: không có 'visudo' để kiểm tra cú pháp -> BỎ QUA phần NOPASSWD" >&2
      echo "    (không dám ghi vào /etc/sudoers.d/ khi chưa validate được — sai cú pháp có thể" >&2
      echo "     làm hỏng sudo toàn máy). Tự thêm tay nếu cần." >&2
      return 0
    fi
    tmpf="$(mktemp)"
    echo "${user} ALL=(ALL) NOPASSWD:ALL" > "$tmpf"
    if $SUDO visudo -c -f "$tmpf" &>/dev/null; then
      $SUDO install -m 440 -o root -g "$( [[ "$OS" == "Darwin" ]] && echo wheel || echo root )" \
        "$tmpf" "/etc/sudoers.d/${user}"
      rm -f "$tmpf"
      echo "    [sudo] đã cấp NOPASSWD qua /etc/sudoers.d/${user} (đã validate cú pháp)."
      # KHÔNG viết `$SUDO -u "$user" ...`: khi chạy bằng root thì $SUDO rỗng, dòng
      # đó thành lệnh `-u` -> luôn fail và báo CẢNH BÁO sai dù NOPASSWD đã hoạt
      # động hoàn hảo (đã gặp thật lúc test). Dùng `su` để đổi user, chạy đúng cả
      # khi là root ($SUDO rỗng) lẫn khi là user thường ($SUDO="sudo").
      if $SUDO su - "$user" -c "sudo -n true" &>/dev/null; then
        echo "    [sudo] đã kiểm chứng: '$user' chạy sudo KHÔNG cần password -> OK."
      else
        echo "    [sudo] CẢNH BÁO: đã ghi file nhưng test 'sudo -n' chưa thành công." >&2
        echo "    Kiểm tra: sudo visudo -c   và   ls -l /etc/sudoers.d/${user} (phải 440 root)" >&2
      fi
    else
      rm -f "$tmpf"
      echo "    [sudo] LỖI: file sudoers sinh ra không hợp lệ -> KHÔNG cài (giữ sudo an toàn)." >&2
    fi
  else
    echo "    [sudo] '$user' có sudo nhưng PHẢI nhập password mỗi lần."
  fi
}

# Tạo thật các remote user đã khai ở đầu script. Chạy sau bước [2/6] để sshd
# chắc chắn đã sẵn sàng, nhờ đó test đăng nhập ngay sau khi tạo mới có ý nghĩa.
create_remote_users() {
  [[ ${#NEW_USERNAMES[@]} -gt 0 ]] || return 0

  local i username password keypath sudomode new_shell new_user_home new_ssh_dir new_group hop2_exit

  if [[ "$OS" == "Darwin" ]]; then
    new_shell="/bin/zsh"; [[ -x "$new_shell" ]] || new_shell="/bin/bash"
  else
    new_shell="/bin/bash"; [[ -x "$new_shell" ]] || new_shell="/bin/sh"
  fi

  for i in "${!NEW_USERNAMES[@]}"; do
    username="${NEW_USERNAMES[$i]}"
    password="${NEW_PASSWORDS[$i]}"
    keypath="${NEW_KEYPATHS[$i]}"
    sudomode="${NEW_SUDOMODES[$i]}"

    echo ""
    echo "  --- User '$username' ---"
    if id "$username" &>/dev/null; then
      echo "    User đã tồn tại -> BỎ QUA tạo mới (giữ nguyên password/cấu hình hiện có)."
    else
      if [[ "$OS" == "Darwin" ]]; then
        if [[ -n "$password" ]]; then
          $SUDO sysadminctl -addUser "$username" -fullName "$username" -password "$password" -home "/Users/$username" -shell "$new_shell"
        else
          # "-password -" = tạo tài khoản KHÔNG có password (không phải "hỏi
          # password"), nên không ai đăng nhập bằng password được, chỉ SSH key.
          $SUDO sysadminctl -addUser "$username" -fullName "$username" -password - -home "/Users/$username" -shell "$new_shell"
        fi
        # sysadminctl chạy bất đồng bộ — đợi tới khi user thực sự xuất hiện.
        for _ in $(seq 1 10); do id "$username" &>/dev/null && break; sleep 1; done
        $SUDO createhomedir -c -u "$username" &>/dev/null || true
      else
        $SUDO useradd -m -s "$new_shell" "$username"
        if [[ -n "$password" ]]; then
          # chpasswd đọc password qua STDIN (không nằm trên dòng lệnh) nên
          # password không lộ ra trong `ps`.
          echo "${username}:${password}" | $SUDO chpasswd
          echo "    Đã đặt password."
        else
          # Khoá password: chỉ chặn ĐĂNG NHẬP BẰNG PASSWORD, không ảnh hưởng
          # đăng nhập bằng SSH key (đã kiểm chứng bằng Docker).
          $SUDO usermod -L "$username" 2>/dev/null || $SUDO passwd -l "$username" 2>/dev/null \
            || echo "    Cảnh báo: không khoá được password, hãy tự kiểm tra thủ công." >&2
        fi
      fi
      if ! id "$username" &>/dev/null; then
        echo "    LỖI: tạo user '$username' thất bại -> bỏ qua user này." >&2
        continue
      fi
      echo "    Đã tạo user (shell $new_shell$( [[ -n "$password" ]] && echo ", có password" || echo ", không password" ))."
    fi

    grant_sudo "$username" "$sudomode"

    if [[ "$OS" == "Darwin" ]]; then
      if $SUDO dscl . -read /Groups/com.apple.access_ssh &>/dev/null; then
        echo "    Remote Login đang giới hạn theo group 'com.apple.access_ssh' -> thêm '$username' vào group."
        $SUDO dseditgroup -o edit -a "$username" -t user com.apple.access_ssh
      fi
    fi

    if [[ -f "$keypath" ]]; then
      echo "    Đã có key tại $keypath -> dùng lại key này."
    else
      mkdir -p "$(dirname "$keypath")"
      ssh-keygen -q -t ed25519 -f "$keypath" -N "" -C "remote-$username-$(date +%Y%m%d)"
      echo "    Đã tạo keypair: $keypath (private) / $keypath.pub (public)"
    fi

    new_user_home="$(get_home_dir "$username")"
    if [[ -z "$new_user_home" || ! -d "$new_user_home" ]]; then
      echo "    LỖI: không tìm thấy home directory của '$username' -> bỏ qua." >&2
      continue
    fi
    new_ssh_dir="$new_user_home/.ssh"
    new_group="$(id -gn "$username")"
    $SUDO mkdir -p "$new_ssh_dir"
    $SUDO touch "$new_ssh_dir/authorized_keys"
    if ! $SUDO grep -qF "$(cat "$keypath.pub")" "$new_ssh_dir/authorized_keys" 2>/dev/null; then
      cat "$keypath.pub" | $SUDO tee -a "$new_ssh_dir/authorized_keys" >/dev/null
      echo "    Đã thêm public key vào $new_ssh_dir/authorized_keys."
    else
      echo "    Key đã có sẵn trong authorized_keys -> bỏ qua (giữ nguyên key khác đã có)."
    fi
    $SUDO chown -R "$username:$new_group" "$new_ssh_dir"
    $SUDO chmod 700 "$new_ssh_dir"
    $SUDO chmod 600 "$new_ssh_dir/authorized_keys"

    # Tự kiểm chứng ngay hop cuối (đăng nhập thẳng vào máy này), không phải chờ
    # gì từ VPS. Dùng `ssh -n` để ssh không nuốt mất STDIN của các `read` sau đó.
    echo "    [Hop cuối] Tự kiểm tra '$username' đăng nhập bằng key mới, không hỏi password..."
    set +e
    ssh -n -i "$keypath" -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new \
      -p "$SSH_LOCAL_PORT" "${username}@127.0.0.1" true 2>/tmp/ssh_hop2_${username}.log
    hop2_exit=$?
    set -e
    if [[ $hop2_exit -eq 0 ]]; then
      echo "    OK — hop cuối đã thông."
    else
      echo "    CẢNH BÁO: hop cuối CHƯA thông (exit $hop2_exit). Chi tiết:" >&2
      cat "/tmp/ssh_hop2_${username}.log" >&2
    fi
  done
}

# In hướng dẫn bàn giao cho các remote user vừa tạo. Chạy ở CUỐI script vì cần
# $remote_ssh_port (chỉ biết sau khi đã chốt port map) và cần tunnel đã dựng xong
# thì test "nhảy qua VPS" mới có ý nghĩa.
report_remote_users() {
  [[ ${#NEW_USERNAMES[@]} -gt 0 ]] || return 0

  local i username keypath hop1_exit

  echo ""
  echo "########################################################################"
  echo "##  BÀN GIAO ${#NEW_USERNAMES[@]} REMOTE USER VỪA TẠO"
  echo "########################################################################"

  for i in "${!NEW_USERNAMES[@]}"; do
    username="${NEW_USERNAMES[$i]}"
    keypath="${NEW_KEYPATHS[$i]}"
    echo ""
    echo "  ── [$username] ──────────────────────────────────────────────────"
    echo "  Có 2 CÁCH để máy-sẽ-SSH đăng nhập được vào '$username'. Chọn 1:"
    echo ""
    echo "  [A] MANG PRIVATE KEY vừa sinh sang máy đó  (mặc định của script)"
    echo "      Hợp khi '$username' là NGƯỜI KHÁC, hoặc máy đó chưa có key SSH nào."
    echo "      Private key: $keypath"
    echo "      ---- BEGIN nội dung private key (copy TOÀN BỘ, gồm cả dòng BEGIN/END) ----"
    cat "$keypath"
    echo "      ---- END nội dung private key ----"
    echo "        # trên MÁY ĐÓ: dán vào ~/.ssh/<tên_file> rồi:  chmod 600 ~/.ssh/<tên_file>"
    echo "        # rồi trỏ IdentityFile trong ~/.ssh/config tới file đó."
    echo "        # (hoặc gửi qua kênh an toàn thay vì copy tay:  scp $keypath <họ>@<máy_của_họ>:~/.ssh/)"
    echo "      Sau khi máy đó đã nhận được key, XOÁ bản trên máy này — đừng để private"
    echo "      key tồn tại ở 2 nơi lâu dài:"
    echo "        shred -u $keypath 2>/dev/null || rm -f $keypath"
    echo ""
    echo "  [B] THÊM PUBLIC KEY của máy đó vào '$username'  (khuyến nghị nếu máy đó đã có key)"
    echo "      Hợp nhất khi '$username' CHÍNH LÀ BẠN, trên 1 máy vốn đã có sẵn keypair"
    echo "      (vd laptop bạn đang dùng để SSH) — lúc đó key script vừa sinh là THỪA."
    echo "      Ưu điểm: KHÔNG có private key nào phải di chuyển, và mỗi thiết bị giữ key"
    echo "      riêng của nó -> thu hồi 1 thiết bị không ảnh hưởng thiết bị khác."
    echo "        # trên MÁY SẼ SSH: lấy public key của nó"
    echo "        cat ~/.ssh/<key>.pub     # hoặc: ssh-keygen -y -f ~/.ssh/<key>"
    echo "        # rồi trên máy này, thêm vào đúng user đó:"
    echo "        echo '<dán public key vào đây>' >> $(get_home_dir "$username" 2>/dev/null || echo "/home/$username")/.ssh/authorized_keys"
    echo "        chown $username: $(get_home_dir "$username" 2>/dev/null || echo "/home/$username")/.ssh/authorized_keys"
    echo "        chmod 600 $(get_home_dir "$username" 2>/dev/null || echo "/home/$username")/.ssh/authorized_keys"
    echo "      (Chọn B thì key script vừa sinh ở trên không cần dùng — xoá đi cho gọn.)"
  done

  if [[ -z "$remote_ssh_port" ]]; then
    echo ""
    echo "  CẢNH BÁO: port map lần này KHÔNG có local_port=22 nên chưa mở đường SSH vào" >&2
    echo "  máy này qua tunnel — các user trên mới chỉ đăng nhập được từ trong mạng LAN." >&2
    echo "  Chạy lại script và thêm 1 port map trỏ tới port SSH của máy này để mở hop đầu." >&2
    echo "########################################################################"
    return 0
  fi

  echo ""
  echo "  CÒN 1 VIỆC BẮT BUỘC: các key trên mới chỉ được MÁY NÀY chấp nhận (hop cuối)."
  echo "  Để các user đó tự nhảy qua VPS (hop đầu, ProxyJump vào '$TUNNEL_USER'), từng key"
  echo "  còn phải được ĐĂNG KÝ THÊM trên VPS. Sang VPS chạy lại vps_setup.sh, nhập ĐÚNG"
  echo "  cùng user '$TUNNEL_USER' (từ v1.4.0, vps_setup.sh tự cộng dồn port với danh sách"
  echo "  đã cấp trước đó — không cần nhớ/gõ lại port cũ), rồi dán lần lượt các public key"
  echo "  dưới đây (vps_setup.sh tự APPEND, không xoá key của người khác đã có sẵn):"
  echo ""
  for i in "${!NEW_USERNAMES[@]}"; do
    echo "  # ${NEW_USERNAMES[$i]}"
    cat "${NEW_KEYPATHS[$i]}.pub"
  done
  echo ""
  ask "  Đã dán xong các public key trên vào vps_setup.sh chưa? Nhấn Enter để tự kiểm tra..."

  for i in "${!NEW_USERNAMES[@]}"; do
    username="${NEW_USERNAMES[$i]}"
    keypath="${NEW_KEYPATHS[$i]}"
    echo "    [Hop đầu] Kiểm tra key của '$username' nhảy qua VPS ('$TUNNEL_USER@$VPS_IP')..."
    set +e
    ssh -n -i "$keypath" -o BatchMode=yes -o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new \
      "${TUNNEL_USER}@${VPS_IP}" true 2>/tmp/ssh_hop1_${username}.log
    hop1_exit=$?
    set -e
    if [[ $hop1_exit -eq 255 ]]; then
      echo "    CẢNH BÁO: key của '$username' CHƯA nhảy qua VPS được. Chi tiết:" >&2
      cat "/tmp/ssh_hop1_${username}.log" >&2
    else
      # Exit code khác 0 (nhưng không phải 255) là bình thường: $TUNNEL_USER bị
      # ép ForceCommand /usr/sbin/nologin nên không chạy được lệnh "true".
      echo "    OK — hop đầu đã thông."
    fi
  done

  echo ""
  echo "  Cấu hình ~/.ssh/config cho MÁY CỦA từng người (thay <private_key> bằng đường"
  echo "  dẫn họ lưu key bạn gửi):"
  echo ""
  echo "    Host vps-jump"
  echo "        HostName $VPS_IP"
  echo "        User $TUNNEL_USER"
  echo "        IdentityFile <private_key>"
  echo "        ServerAliveInterval 30"
  echo "        ServerAliveCountMax 3"
  echo "        TCPKeepAlive yes"
  for i in "${!NEW_USERNAMES[@]}"; do
    username="${NEW_USERNAMES[$i]}"
    echo ""
    echo "    Host home-$username"
    echo "        HostName localhost"
    echo "        Port $remote_ssh_port"
    echo "        User $username"
    echo "        ProxyJump vps-jump"
    echo "        IdentityFile <private_key>"
    echo "        ServerAliveInterval 30"
    echo "        ServerAliveCountMax 3"
    echo "        TCPKeepAlive yes"
  done
  echo ""
  echo "  Rồi họ dùng: ssh home-<tên_user>"
  echo "########################################################################"
}

# Kiểm chứng tunnel có THỰC SỰ mở được port trên VPS hay không.
#
# Vì sao bắt buộc phải có: `systemctl is-active` (hoặc `launchctl list`) chỉ cho
# biết autossh ĐANG CHẠY — hoàn toàn không nói forward có thành công hay không.
# Nếu remote_port đã bị 1 tunnel khác chiếm (máy khác, hoặc service tunnel CŨ của
# chính máy này còn sót lại), sshd trên VPS từ chối bind, ssh chỉ ghi 1 dòng
#     Warning: remote port forwarding failed for listen port N
# rồi autossh lặng lẽ thử lại mãi. Service vẫn "active" nên script BÁO ✔ NHẦM —
# tunnel "chạy" suốt mà không ai vào được. Đây là bug thật đã gặp, và trước đây
# script còn ghi hẳn "máy local không thể tự kiểm chứng port đã bind trên VPS":
# hoá ra kiểm chứng được, chỉ cần đọc log của chính service vừa tạo.
report_forward_status() {
  local logtext="$1"
  if echo "$logtext" | grep -qiE "remote port forwarding failed"; then
    echo "" >&2
    echo "########################################################################" >&2
    echo "##  LỖI: tunnel ĐANG CHẠY nhưng KHÔNG mở được port trên VPS           ##" >&2
    echo "########################################################################" >&2
    echo "$logtext" | grep -iE "remote port forwarding failed" | tail -3 >&2
    echo "" >&2
    echo "  Nghĩa là autossh kết nối tới VPS OK, nhưng VPS TỪ CHỐI mở remote_port." >&2
    echo "  2 nguyên nhân thường gặp:" >&2
    echo "   1) remote_port ĐANG BỊ CHIẾM trên VPS — bởi máy khác, hoặc bởi chính" >&2
    echo "      service tunnel CŨ của máy này còn sót (xem cảnh báo unit trùng phía trên)." >&2
    echo "      Kiểm tra trên VPS:  sudo ss -tlnp | grep <remote_port>" >&2
    echo "   2) remote_port chưa nằm trong PermitListen của user tunnel trên VPS" >&2
    echo "      -> chạy lại vps_setup.sh và khai thêm port này (từ v1.4.0 tự cộng dồn" >&2
    echo "      với port cũ, không cần gõ lại danh sách port đã cấp trước đó)." >&2
    echo "########################################################################" >&2
    return 1
  fi
  echo "    [forward] đã kiểm chứng qua log: không có lỗi 'remote port forwarding failed' -> port trên VPS đã mở thật."
  return 0
}

verify_tunnel_forward() {
  local kind="$1" ref="$2" logtext=""
  sleep 3   # chờ autossh kết nối xong và thử mở port trên VPS
  case "$kind" in
    system) logtext="$($SUDO journalctl -u "$ref" -n 80 --no-pager 2>/dev/null || true)" ;;
    user)   logtext="$(journalctl --user -u "$ref" -n 80 --no-pager 2>/dev/null || true)" ;;
    file)   logtext="$($SUDO tail -n 80 "$ref" 2>/dev/null || true)" ;;
  esac
  if [[ -z "$logtext" ]]; then
    echo "    [forward] không đọc được log ($kind: $ref) -> bỏ qua bước kiểm chứng forward." >&2
    return 0
  fi
  report_forward_status "$logtext" || true
}

# Bản script <= 1.5.0 luôn tạo service kiểu `systemd --user`, KỂ CẢ khi chạy bằng
# root. Từ 1.6.0 chạy bằng root sẽ tạo system unit TRÙNG TÊN. Nếu unit --user cũ
# vẫn còn chạy, nó GIỮ remote_port trên VPS và unit mới không bind được — nhưng
# vẫn "active" nên cực khó nhận ra. (Bug thật: 2 autossh song song cùng trỏ 1 port,
# cái cũ 11 tiếng giữ port và forward sai đích, cái mới đúng thì bị chặn.)
warn_stale_user_unit() {
  local name="$1"
  command -v systemctl &>/dev/null || return 0
  if systemctl --user is-active --quiet "$name" 2>/dev/null; then
    echo "" >&2
    echo "    CẢNH BÁO: còn 1 service tunnel CŨ TRÙNG TÊN đang chạy ở cấp --user:" >&2
    echo "      $name" >&2
    echo "    Nó do bản script cũ tạo ra (bản cũ dùng systemd --user kể cả khi chạy root)," >&2
    echo "    và đang GIỮ remote_port trên VPS khiến service mới không bind được." >&2
    echo "    Dừng hẳn nó rồi khởi động lại service mới:" >&2
    echo "      systemctl --user stop $name && systemctl --user disable $name" >&2
    echo "      systemctl restart $name" >&2
  fi
}

echo "==> [1/6] Kiểm tra / cài autossh"
ensure_pkg "autossh" "command -v autossh" "autossh" || { echo "Cài autossh thủ công rồi chạy lại." >&2; exit 1; }
AUTOSSH_BIN="$(command -v autossh)"

echo ""
echo "==> [2/6] Kiểm tra các port đích trên máy này (local_port) đã sẵn sàng chưa"
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
    # "Có người nghe" CHƯA chắc là service của chính máy/distro này. Trên WSL2,
    # mọi distro dùng chung network namespace nên port 22 bạn thấy có thể là sshd
    # của distro KHÁC -> tunnel sẽ trỏ nhầm sang distro đó mà không báo gì.
    if port_owned_here "$local_p"; then
      echo "    [port] $local_p: đã có service lắng nghe -> BỎ QUA (không cần cài gì)."
    else
      echo "" >&2
      echo "    [port] $local_p: CẢNH BÁO NGHIÊM TRỌNG — port đang bị giữ bởi 1 tiến trình" >&2
      echo "    KHÔNG thuộc máy/distro này (ss thấy port nhưng không thấy tiến trình nào)." >&2
      if is_wsl; then
        echo "    Máy này là WSL: mọi distro WSL2 dùng CHUNG network namespace, nên rất có thể" >&2
        echo "    port $local_p đang thuộc về 1 distro WSL KHÁC trên cùng máy Windows." >&2
        echo "    Nếu cứ tiếp tục, tunnel sẽ forward sang sshd của distro KIA — bạn tưởng đang" >&2
        echo "    SSH vào distro này nhưng thật ra vào distro khác (rất khó phát hiện)." >&2
        echo "    CÁCH SỬA: cho distro này dùng port riêng, vd khai port map <remote_port>:2224" >&2
        echo "    rồi để script tự cấu hình sshd nghe 2224." >&2
      fi
      UNVERIFIED_PORTS+=("$pm (local_port $local_p bị tiến trình NGOÀI distro này chiếm — có thể là distro WSL khác)")
    fi
    continue
  fi

  if [[ -n "$SSH_LOCAL_PORT" && "$local_p" == "$SSH_LOCAL_PORT" ]]; then
    echo "    [port] $local_p: CHƯA có gì lắng nghe — cần sshd để nhận SSH vào máy này."
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

      # Nếu cần sshd ở port KHÁC 22 thì phải làm 2 việc, thiếu 1 trong 2 là hỏng:
      #   1) khai Port trong sshd_config, VÀ
      #   2) tắt socket activation — vì khi ssh.socket còn bật thì chính nó giữ
      #      port, "Port" trong sshd_config bị bỏ qua hoàn toàn.
      if [[ "$local_p" != "22" ]]; then
        set_sshd_port "$local_p" || true
        disable_ssh_socket_activation
      fi
      # QUAN TRỌNG: chỉ có "systemctl" trong PATH không có nghĩa là systemd đang
      # thực sự chạy làm init (PID 1) — container/WSL1/chroot thường có binary
      # nhưng gọi vào sẽ lỗi "Host is down". Phải verify bằng port_is_listening
      # thật sự rồi mới fallback sang "service", không được tin suông vào việc
      # binary tồn tại (đã tái hiện được lỗi này bằng test thật).
      SSHD_STARTED=0
      if command -v systemctl &>/dev/null; then
        echo "    [service] đang thử bật sshd qua systemctl..."
        ENABLE_ERR="$( { $SUDO systemctl enable --now ssh || $SUDO systemctl enable --now sshd; } 2>&1)" || true
        # RESTART chứ không chỉ enable --now: nếu sshd ĐANG CHẠY SẴN với cấu hình
        # cũ thì "start"/"enable --now" không làm gì cả, sshd vẫn giữ nguyên port
        # cũ dù sshd_config vừa được đổi -> script tưởng đã cấu hình xong nhưng
        # port mới không bao giờ mở. (Bug thật: sshd_config ghi Port 24 nhưng sshd
        # vẫn nghe 2224 vì chưa hề được nạp lại.)
        $SUDO systemctl restart ssh 2>/dev/null || $SUDO systemctl restart sshd 2>/dev/null || true
        if echo "$ENABLE_ERR" | grep -qi "could not be found"; then
          echo "    [service] systemctl báo KHÔNG tìm thấy unit ssh/sshd -> gói openssh-server" \
               "thực ra chưa cài xong dù bước kiểm tra trước đó tưởng đã có. Đang cài lại..."
          install_pkg openssh-server || install_pkg openssh || true
          $SUDO systemctl daemon-reload 2>/dev/null || true
          $SUDO systemctl enable --now ssh 2>/dev/null || $SUDO systemctl enable --now sshd 2>/dev/null || true
        fi
        # "A dependency job for ssh.service failed" = gần như luôn do ssh.socket
        # không bind được port (vd port đã bị distro WSL khác giữ). Sửa bằng cách
        # tắt socket activation rồi thử lại, thay vì bỏ cuộc với 1 thông báo khó hiểu.
        if echo "$ENABLE_ERR" | grep -qiE "dependency job .* failed|Failed to listen on"; then
          echo "    [service] systemctl báo lỗi phụ thuộc -> nghi do socket activation (ssh.socket)."
          disable_ssh_socket_activation
          $SUDO systemctl restart ssh 2>/dev/null || $SUDO systemctl restart sshd 2>/dev/null || true
        fi
        sleep 1
        if port_is_listening "$local_p"; then
          SSHD_STARTED=1
          echo "    [service] systemctl: THÀNH CÔNG (port $local_p đã lắng nghe)."
        else
          echo "    [service] systemctl: không có tác dụng thật (thường do container/WSL1/chroot" \
               "không có systemd PID 1 thật) -> fallback sang 'service'."
        fi
      fi
      if [[ $SSHD_STARTED -eq 0 ]]; then
        echo "    [service] đang thử bật sshd qua 'service'..."
        # restart (không phải start) — lý do như trên: sshd đang chạy sẵn sẽ bỏ qua "start".
        $SUDO service ssh restart 2>/dev/null || $SUDO service sshd restart 2>/dev/null \
          || $SUDO service ssh start 2>/dev/null || $SUDO service sshd start 2>/dev/null || true
      fi
    fi
    sleep 1
    if port_is_listening "$local_p"; then
      echo "    [port] $local_p: đã lắng nghe sau khi cài/bật sshd -> OK."
    else
      echo "    [port] $local_p: CẢNH BÁO — vẫn CHƯA lắng nghe sau khi cố cài/bật sshd." >&2
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

if [[ ${#NEW_USERNAMES[@]} -gt 0 ]]; then
  echo ""
  echo "==> [3/6] Tạo ${#NEW_USERNAMES[@]} remote user đã khai ở đầu script"
  create_remote_users
  echo ""
else
  echo "==> [3/6] Không có remote user nào cần tạo -> BỎ QUA."
fi

echo "==> [4/6] Test kết nối SSH tới VPS trước khi tạo service nền"
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
  ask "Vẫn tiếp tục cài service nền? (y/N) " "n"; ans="$ASK_REPLY"
  [[ "$ans" =~ ^[Yy]$ ]] || exit 1
else
  # Exit code khác 0 (nhưng không phải 255) là bình thường: user tunnel bị ép
  # ForceCommand /usr/sbin/nologin nên không chạy lệnh "true" được, nhưng auth đã OK.
  echo "    Kết nối SSH tới VPS OK (xác thực thành công)."
fi

echo "==> [5/6] Tạo ~/.ssh/config entry để truy cập máy local qua VPS"
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

# remote_port nào trên VPS dẫn tới sshd của máy này — dựa vào $SSH_LOCAL_PORT
# (không còn giả định cứng là 22, xem lý do ở phần xác định SSH_LOCAL_PORT).
remote_ssh_port=""
for pm in "${PORT_MAPS[@]}"; do
  if [[ -n "$SSH_LOCAL_PORT" && "${pm#*:}" == "$SSH_LOCAL_PORT" ]]; then
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
  echo "    riêng đã khai ở đầu script, an toàn hơn nhiều so với login thẳng root)"
  ask "    Mở SSH vào root? (y/N): " "n"; ans="$ASK_REPLY"
  if [[ "$ans" =~ ^[Yy]$ ]]; then
    AUTHORIZE_SELF=1
  else
    AUTHORIZE_SELF=0
    echo "    -> BỎ QUA (không mở SSH vào root). Dùng các remote user tạo ở bước [3/6]."
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
  echo "    ServerAliveInterval 30"
  echo "    ServerAliveCountMax 3"
  echo "    TCPKeepAlive yes"
  if [[ -n "$remote_ssh_port" && $AUTHORIZE_SELF -eq 1 ]]; then
    echo ""
    echo "Host home"
    echo "    HostName localhost"
    echo "    Port $remote_ssh_port"
    echo "    User $USER"
    echo "    ProxyJump vps-jump"
    echo "    IdentityFile $KEY_PATH"
    echo "    ServerAliveInterval 30"
    echo "    ServerAliveCountMax 3"
    echo "    TCPKeepAlive yes"
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
    echo "==> [6/6] Tạo LaunchDaemon (macOS, chạy bằng root) để tunnel tự chạy nền + tự reconnect"
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
      verify_tunnel_forward file "/var/log/${PLIST_LABEL}.err.log"
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
    echo "==> [6/6] Tạo systemd system service (Linux, chạy bằng root) để tunnel tự chạy nền + tự reconnect"

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
      warn_stale_user_unit "$SERVICE_NAME"
      verify_tunnel_forward system "$SERVICE_NAME"
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
  echo "==> [6/6] Tạo LaunchAgent (macOS) để tunnel tự chạy nền + tự reconnect"
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
    verify_tunnel_forward file "/tmp/${PLIST_LABEL}.err.log"
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
  echo "==> [6/6] Tạo systemd --user service (Linux) để tunnel tự chạy nền + tự reconnect"

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
    verify_tunnel_forward user "$SERVICE_NAME"
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
  echo "  - Chưa có tài khoản nào SSH vào máy này được qua tunnel — dùng các remote user tạo ở bước [3/6]."
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

# In 1 cặp Host (nhảy qua VPS + đích cuối là máy này) cho ~/.ssh/config trên máy client.
# Tham số: <tên Host jump> <tên Host đích> <user trên máy này> <đường dẫn private key>
# Host để SÁT LỀ TRÁI vì khối này được dùng làm heredoc dán thẳng vào terminal và làm
# file config tạm cho phần tự kiểm tra. IdentitiesOnly để ssh không thử key lạ trong agent.
print_ssh_config_pair() {
  local jump="$1" dest="$2" duser="$3" ident="$4"
  echo ""
  echo "Host $jump"
  echo "    HostName $VPS_IP"
  echo "    User $TUNNEL_USER"
  echo "    IdentityFile $ident"
  echo "    IdentitiesOnly yes"
  echo "    ServerAliveInterval 30"
  echo "    ServerAliveCountMax 3"
  echo "    TCPKeepAlive yes"
  echo ""
  echo "Host $dest"
  echo "    HostName localhost"
  echo "    Port $remote_ssh_port"
  echo "    User $duser"
  echo "    ProxyJump $jump"
  echo "    IdentityFile $ident"
  echo "    IdentitiesOnly yes"
  echo "    ServerAliveInterval 30"
  echo "    ServerAliveCountMax 3"
  echo "    TCPKeepAlive yes"
}

# In lệnh chuyển 1 private key sang máy client mà KHÔNG bị hỏng định dạng.
# Copy-paste key nhiều dòng qua terminal hay làm hỏng file (thừa khoảng trắng, ký tự \r,
# mất dòng cuối) -> ssh báo "invalid format" / "is not a public key file" và KHÔNG gửi key
# nào lên VPS (VPS chỉ thấy "Permission denied (publickey)"). Mã hoá base64 thành MỘT dòng
# thì copy không hỏng được. Tham số: <file private key ở máy này> <đường dẫn đích trên client>
print_key_transfer() {
  local src="$1" dest="$2" b64
  b64="$(base64 < "$src" | tr -d '\n')"
  echo ""
  echo "mkdir -p ~/.ssh && chmod 700 ~/.ssh && echo '$b64' | (base64 -d 2>/dev/null || base64 -D) > $dest && chmod 600 $dest && ssh-keygen -y -f $dest"
  echo ""
  echo "      (dán nguyên 1 dòng; cuối cùng phải hiện 'ssh-ed25519 AAAA...')"
}

# Tổng kết cuối cùng: gom MỘT chỗ mọi thông tin kết nối để người dùng lưu lại, khỏi
# phải lội ngược log dài. Chỉ in khi mọi bước trước đó đã thành công (lỗi thì script
# đã `exit 1` từ trước).
print_final_summary() {
  local svc="${SERVICE_NAME:-${PLIST_LABEL:-}}"
  local can_login_self=0
  [[ -n "$remote_ssh_port" && $AUTHORIZE_SELF -eq 1 ]] && can_login_self=1

  echo ""
  echo "########################################################################"
  echo "##  TỔNG KẾT"
  echo "########################################################################"
  echo "  VPS         : $VPS_IP   (user tunnel: $TUNNEL_USER)"
  echo "  Port map    : ${PORT_MAPS[*]}   (remote_port:local_port)"
  [[ -z "$svc" ]] || echo "  Service nền : $svc"
  echo "  Private key : $KEY_PATH   (giữ bí mật, KHÔNG xoá — tunnel cần file này)"
  echo "  Public key  : $(cat "$KEY_PATH.pub")"

  if [[ -z "$remote_ssh_port" ]]; then
    echo ""
    echo "  Port map không có local_port 22 nên chưa có đường SSH vào máy này qua tunnel."
    echo "########################################################################"
    return 0
  fi

  echo ""
  echo "  ── KẾT NỐI TỪ MÁY KHÁC ─────────────────────────────────────────────"
  echo "  Có 3 máy, đừng nhầm:"
  echo "    MÁY NÀY   = máy đang chạy script (máy đích, sau NAT)  -> ĐÃ XONG, không làm gì thêm"
  echo "    VPS       = $VPS_IP                                   -> ĐÃ XONG, không làm gì thêm"
  echo "    MÁY CLIENT = máy bạn sẽ ngồi gõ ssh (laptop, máy khác) -> làm 3 bước dưới đây"
  echo "  Cả 2 hop dùng chung 1 private key; public key đã cài sẵn ở VPS và máy này."
  echo "  => Máy client chỉ cần có file private key, KHÔNG phải add public key."

  local listed=0 i uname ukey kfile kdest kuser
  if [[ $can_login_self -eq 1 ]]; then
    listed=1
    kfile="$KEY_PATH"; kdest="~/.ssh/vps_tunnel"; kuser="$USER"
  elif [[ ${#NEW_USERNAMES[@]} -gt 0 ]]; then
    listed=1
    kfile="${NEW_KEYPATHS[0]}"; kdest="~/.ssh/${NEW_KEYPATHS[0]##*/}"; kuser="${NEW_USERNAMES[0]}"
  fi

  if [[ $listed -eq 1 ]]; then
    echo ""
    echo "  [1] Trên MÁY CLIENT — chép private key (mở terminal máy client, dán):"
    print_key_transfer "$kfile" "$kdest"
    echo ""
    echo "  [2] Trên MÁY CLIENT — thêm config (cũng dán vào terminal máy client):"
    echo ""
    echo "cat >> ~/.ssh/config <<'SSHCFG'"
    print_ssh_config_pair "vps-jump" "home" "$kuser" "$kdest"
    echo "SSHCFG"
    echo "chmod 600 ~/.ssh/config"
    echo ""
    echo "  [3] Trên MÁY CLIENT — kết nối:   ssh home"
    echo ""
    echo "  Lỗi thường gặp (xem log ở MÁY CLIENT, trừ dòng ghi rõ máy khác):"
    echo "    no such identity / invalid format   -> sai đường dẫn hoặc file key hỏng: làm lại [1]"
    echo "    Permission denied (publickey)       -> chạy 'ssh -v home 2>&1 | grep Offering'."
    echo "                                           Không thấy dòng nào = ssh chưa đọc được key (làm lại [1])."
    echo "                                           Có dòng mà vẫn bị từ chối = key chưa cài trên VPS."
    if [[ "$OS" == "Darwin" ]]; then
      echo "    Connection refused / timed out      -> tunnel chưa chạy. Kiểm tra trên MÁY NÀY: launchctl list | grep vpstunnel"
    elif [[ $IS_ROOT -eq 1 ]]; then
      echo "    Connection refused / timed out      -> tunnel chưa chạy. Kiểm tra trên MÁY NÀY: systemctl status ${SERVICE_NAME:-vpstunnel-*.service}"
    else
      echo "    Connection refused / timed out      -> tunnel chưa chạy. Kiểm tra trên MÁY NÀY: systemctl --user status ${SERVICE_NAME:-vpstunnel-*.service}"
    fi
    echo "    Kẹt ở hop 1 (tới VPS)               -> sshd VPS không ở port 22: thêm 'Port <n>' vào Host vps-jump (trên MÁY CLIENT)"
    echo "  (Nhiều máy qua 1 jump: giữ 1 'vps-jump', mỗi máy đích 1 Host riêng, khác Port và User.)"
  fi

  if [[ ${#NEW_USERNAMES[@]} -gt 0 ]]; then
    echo ""
    echo "  ── REMOTE USER (key riêng) ──"
    echo "  Trước: trên VPS, chạy lại vps_setup.sh, nhập user '$TUNNEL_USER', dán public key của họ."
    echo "  Sau đó trên MÁY CLIENT của từng người:"
    for i in "${!NEW_USERNAMES[@]}"; do
      uname="${NEW_USERNAMES[$i]}"
      ukey="~/.ssh/${NEW_KEYPATHS[$i]##*/}"
      echo ""
      echo "  [$uname] Trên MÁY CLIENT của $uname — chép key:"
      print_key_transfer "${NEW_KEYPATHS[$i]}" "$ukey"
      echo ""
      echo "  [$uname] Trên MÁY CLIENT của $uname — thêm config, rồi dùng:  ssh home-$uname"
      echo ""
      echo "cat >> ~/.ssh/config <<'SSHCFG'"
      print_ssh_config_pair "vps-jump-$uname" "home-$uname" "$uname" "$ukey"
      echo "SSHCFG"
    done
  fi

  if [[ $listed -eq 0 ]]; then
    echo ""
    echo "  Chưa có tài khoản nào SSH vào máy này được (đã chọn không mở SSH vào root và"
    echo "  không tạo remote user). Mẫu để điền khi có user + key:"
    print_ssh_config_pair "vps-jump" "home" "<user_trên_máy_này>" "<private_key>"
  fi
  echo "########################################################################"
}

report_remote_users
print_final_summary

