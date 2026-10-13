#!/usr/bin/env bash
#
# vps_setup.sh — Tạo user "tunnel-only" trên VPS để nhận SSH reverse tunnel.
# User tạo ra KHÔNG có shell, chỉ được phép forward đúng các port đã khai báo.
#
# Usage (chạy bằng root/sudo trên VPS):
#   sudo ./vps_setup.sh
# Script hỏi các thông tin cần thiết, không cần sửa file hay truyền tham số.
#
# THIẾT KẾ (đã kiểm chứng thực nghiệm bằng Docker trước khi viết bản này):
#   - sshd xử lý "AllowTcpForwarding/PermitListen/..." theo quy tắc GIÁ TRỊ ĐẦU TIÊN
#     NHẬN ĐƯỢC THẮNG, kể cả khi giá trị đó nằm trong 1 Match block ở file được
#     Include SỚM HƠN trong thứ tự xử lý — bất kể block nào "nằm sau" trong nội
#     dung merge cuối cùng. Vì vậy KHÔNG append vào cuối /etc/ssh/sshd_config (dễ bị
#     1 file khác trong sshd_config.d/ đè mất, gây forward bị từ chối âm thầm).
#   - Thay vào đó, ghi TOÀN BỘ cấu hình vào 1 file riêng
#     /etc/ssh/sshd_config.d/00-tunnel-<username>.conf — tiền tố "00-" đảm bảo file
#     này được glob-sort và Include TRƯỚC các file đánh số cao hơn (10-, 20-, 50-...),
#     nên luôn thắng trong trường hợp phổ biến. Script cũng tự phát hiện file nào
#     khác cũng match cùng username, và tự VERIFY lại bằng `sshd -T -C` sau khi
#     restart để chứng minh cấu hình thực sự có hiệu lực (không chỉ giả định).
#   - Không đụng vào /etc/ssh/sshd_config gốc -> an toàn, dễ gỡ (chỉ cần xoá 1 file).
#
SCRIPT_VERSION="1.6.0"

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "Lỗi: cần chạy bằng root (sudo ./vps_setup.sh)" >&2
  exit 1
fi

# Cài 1 package qua bất kỳ package manager nào có sẵn (apt/dnf/yum/pacman/zypper/apk).
# In rõ đang dùng trình quản lý gói nào để dễ theo dõi log.
install_pkg() {
  local pkg="$1"
  if command -v apt-get &>/dev/null; then
    echo "    [gói] dùng apt-get để cài '$pkg'..."
    apt-get update -y -qq
    apt-get install -y "$pkg"
  elif command -v dnf &>/dev/null; then
    echo "    [gói] dùng dnf để cài '$pkg'..."
    dnf install -y "$pkg"
  elif command -v yum &>/dev/null; then
    echo "    [gói] dùng yum để cài '$pkg'..."
    yum install -y "$pkg"
  elif command -v pacman &>/dev/null; then
    echo "    [gói] dùng pacman để cài '$pkg'..."
    pacman -Sy --noconfirm "$pkg"
  elif command -v zypper &>/dev/null; then
    echo "    [gói] dùng zypper để cài '$pkg'..."
    zypper install -y "$pkg"
  elif command -v apk &>/dev/null; then
    echo "    [gói] dùng apk để cài '$pkg'..."
    apk add "$pkg"
  else
    echo "    [gói] '$pkg': CÀI THẤT BẠI — không tìm được trình quản lý gói phù hợp." >&2
    return 1
  fi
}

# Kiểm tra 1 lệnh/binary đã có chưa; nếu chưa thì cài qua install_pkg, rồi verify
# lại. In rõ BỎ QUA / ĐANG CÀI / CÀI THÀNH CÔNG / CÀI THẤT BẠI cho từng gói.
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

echo "=== Setup user tunnel trên VPS (vps_setup.sh v$SCRIPT_VERSION) ==="
echo ""
cat <<'GUIDE'
########################################################################
##  LỘ TRÌNH TỔNG THỂ — 4 bước, chạy ở 3 nơi khác nhau
########################################################################

  [Máy LOCAL: nhà/sau NAT] --tunnel--> [VPS] <--ssh-- [LAPTOP của bạn]

  BƯỚC 1 — trên máy LOCAL (máy muốn được truy cập từ xa)
           Chạy local_setup.sh. Nó tạo 1 cặp key và IN RA PUBLIC KEY
           (dòng ssh-ed25519 ...). Copy dòng này, rồi DỪNG ở câu
           "Đã setup user tunnel trên VPS chưa?" — để cửa sổ đó mở.

  BƯỚC 2 — trên VPS   <<< BẠN ĐANG Ở ĐÂY (vps_setup.sh)
           Dán public key ở bước 1, chọn tên user tunnel và remote_port.
           Script tạo user "chỉ để tunnel" (không shell, không login) và
           chỉ cho phép nó mở đúng các port bạn khai.
           Cuối script báo '✔ HOÀN TẤT'. Nhớ: tên user + remote_port.

  BƯỚC 3 — quay lại máy LOCAL (cửa sổ đang dừng ở bước 1)
           Nhấn Enter, nhập IP VPS, tên user và Port map (dạng
           remote_port:local_port, vd 2201:22). Script cài autossh, tạo
           service chạy nền tự nối lại -> tunnel mở, máy LOCAL đã "gọi" ra VPS.

  BƯỚC 4 — trên LAPTOP của bạn (thiết bị dùng để SSH từ xa)
           Chép private key + đoạn ~/.ssh/config mà local_setup.sh in ra,
           rồi gõ:  ssh home   (đi qua VPS vào máy LOCAL).

  THÊM MÁY THỨ 2 vào cùng VPS: lặp bước 1-3 với key mới + remote_port MỚI
  (không trùng máy đầu). Ở bước 2 gõ CÙNG tên user, CHỈ nhập port mới.

########################################################################
GUIDE
echo ""
read -r -p "Đã hiểu lộ trình? Nhấn Enter để bắt đầu BƯỚC 2 (Ctrl+C để thoát)... " _ || true
echo ""

echo "==> [1/8] Kiểm tra sshd đã cài chưa (thường đã có sẵn vì bạn đang SSH vào máy này)"
ensure_pkg "openssh-server (sshd)" "command -v sshd || [[ -x /usr/sbin/sshd ]]" "openssh-server" \
  || install_pkg openssh
echo ""

echo "Ví dụ tên user: tunneluser  hoặc  jump  (nhiều máy dùng chung VPS thì gõ cùng 1 tên)"
read -r -p "Tên user tunnel [tunneluser]: " USERNAME
USERNAME="${USERNAME:-tunneluser}"
if ! [[ "$USERNAME" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
  echo "Lỗi: tên user không hợp lệ (chỉ chữ thường, số, '_', '-', bắt đầu bằng chữ hoặc '_')." >&2
  exit 1
fi

echo ""
echo "Dán 1 dòng public key (vd: ssh-ed25519 AAAAC3Nza...xyz vps-tunnel-20261013)"
echo "hoặc đường dẫn file .pub trên VPS (vd: /root/vps_tunnel.pub)"
echo "(Chưa có key? Ctrl+C, chạy local_setup.sh trên máy LOCAL trước — bước 1.)"
read -r -p "Public key (đường dẫn hoặc nội dung): " PUBKEY_INPUT
echo ""

if [[ -z "$PUBKEY_INPUT" ]]; then
  echo "Lỗi: chưa nhập public key." >&2
  exit 1
fi

# Nếu public key được trỏ bằng ĐƯỜNG DẪN file trên chính VPS (không phải dán nội
# dung), rất có thể keypair đã được sinh sẵn NGAY TRÊN VPS (vd ssh-keygen chạy tại
# đây) thay vì trên máy client — ghi lại đường dẫn private key tương ứng (bỏ đuôi
# ".pub") để cuối script gợi ý cách tải AN TOÀN private key đó về máy client.
PRIVATE_KEY_ON_VPS_HINT=""
if [[ "$PUBKEY_INPUT" =~ ^(ssh-ed25519|ssh-rsa|ecdsa-sha2-) ]]; then
  PUBKEY_CONTENT="$PUBKEY_INPUT"
elif [[ -f "$PUBKEY_INPUT" ]]; then
  PUBKEY_CONTENT="$(cat "$PUBKEY_INPUT")"
  CANDIDATE_PRIVATE_KEY="${PUBKEY_INPUT%.pub}"
  if [[ "$CANDIDATE_PRIVATE_KEY" != "$PUBKEY_INPUT" && -f "$CANDIDATE_PRIVATE_KEY" ]]; then
    PRIVATE_KEY_ON_VPS_HINT="$CANDIDATE_PRIVATE_KEY"
  fi
else
  echo "Lỗi: không tìm thấy file '$PUBKEY_INPUT' và nội dung nhập vào không phải public key hợp lệ." >&2
  exit 1
fi

if ! [[ "$PUBKEY_CONTENT" =~ ^(ssh-ed25519|ssh-rsa|ecdsa-sha2-) ]]; then
  echo "Lỗi: nội dung public key trông không hợp lệ (phải bắt đầu bằng ssh-ed25519/ssh-rsa/ecdsa-sha2-...)." >&2
  exit 1
fi

echo "Nhập danh sách port trên VPS sẽ dùng để nhận reverse tunnel (remote_port trong port map"
echo "của local_setup.sh), cách nhau bởi dấu cách. Chỉ các port này mới được phép forward."
echo ""
echo "  QUY TẮC: mỗi MÁY phải dùng remote_port RIÊNG, không được trùng máy khác (trùng thì"
echo "  máy kết nối sau sẽ không mở được port). Chọn port > 1024, chưa có dịch vụ nào dùng."
echo ""
echo "  Ví dụ:"
echo "    2222              -> 1 máy, chỉ SSH vào máy đó"
echo "    2222 8080         -> 1 máy, SSH (2222) + 1 web app (8080)"
echo "    2201 2202 2203    -> 3 máy, mỗi máy 1 port SSH riêng (máy A=2201, B=2202, C=2203)"
echo ""
echo "  Thêm máy mới sau này: chạy lại script, nhập CÙNG tên user và CHỈ port mới (vd 2204)."
echo "  Port đã cấp cho các máy trước được giữ nguyên, không cần gõ lại."
echo ""

# Cho phép để trống CHỈ khi user này đã có danh sách port từ lần chạy trước (trường
# hợp chỉ muốn thêm key của máy/người khác, không thêm port mới). Lần đầu thì bắt buộc nhập.
EXISTING_DROPIN="/etc/ssh/sshd_config.d/00-tunnel-${USERNAME}.conf"
HAS_EXISTING_PORTS=0
if [[ -f "$EXISTING_DROPIN" ]] && grep -qE '^[[:space:]]*PermitListen[[:space:]]' "$EXISTING_DROPIN"; then
  HAS_EXISTING_PORTS=1
fi

PORTS_RAW=""
if [[ $HAS_EXISTING_PORTS -eq 1 ]]; then
  echo "  (User '$USERNAME' đã có port từ trước — có thể để trống nếu chỉ thêm key, không thêm port.)"
  read -r -p "Danh sách port [Enter = giữ nguyên port cũ]: " PORTS_RAW || true
else
  read -r -p "Danh sách port (vd: 2222 8080): " PORTS_RAW || true
  if [[ -z "${PORTS_RAW// /}" ]]; then
    echo "Lỗi: chưa nhập port nào. Cần ít nhất 1 port, vd: 2222" >&2
    exit 1
  fi
fi

TUNNEL_PORTS=()
read -r -a TUNNEL_PORTS <<< "$PORTS_RAW"
for p in ${TUNNEL_PORTS[@]+"${TUNNEL_PORTS[@]}"}; do
  if ! [[ "$p" =~ ^[0-9]+$ ]] || (( 10#$p < 1 || 10#$p > 65535 )); then
    echo "Lỗi: port '$p' không hợp lệ (phải là số từ 1 đến 65535)." >&2
    exit 1
  fi
done
echo ""

echo "==> [2/8] Tạo user '$USERNAME' (không có shell, chỉ dùng để tunnel)"
if ! id "$USERNAME" &>/dev/null; then
  useradd -m -s /usr/sbin/nologin "$USERNAME"
  echo "    Đã tạo user $USERNAME"
else
  echo "    User $USERNAME đã tồn tại, bỏ qua bước tạo user."
fi

USER_HOME="$(getent passwd "$USERNAME" | cut -d: -f6)"
SSH_DIR="$USER_HOME/.ssh"

echo "==> [3/8] Cài public key vào $SSH_DIR/authorized_keys"
mkdir -p "$SSH_DIR"
touch "$SSH_DIR/authorized_keys"
# APPEND nếu key chưa có, KHÔNG ghi đè cả file — user tunnel-only này thường cần
# nhiều máy client cùng xác thực vào (vd máy tự chạy reverse-tunnel + máy dùng để
# ProxyJump vào tunnel đó). Trước đây dùng "> authorized_keys" (ghi đè) nên chạy
# vps_setup.sh lần 2 cho cùng user với key của máy khác sẽ ÂM THẦM xoá key máy
# đầu, gây lỗi "Permission denied (publickey)" khó hiểu ở máy đó (bug thật đã gặp).
if grep -qF "$PUBKEY_CONTENT" "$SSH_DIR/authorized_keys" 2>/dev/null; then
  echo "    Key đã có sẵn trong authorized_keys, bỏ qua (không đụng tới các key khác đang có)."
else
  echo "$PUBKEY_CONTENT" >> "$SSH_DIR/authorized_keys"
  echo "    Đã thêm key (giữ nguyên các key khác đã có sẵn, nếu có)."
fi
chown -R "$USERNAME:$USERNAME" "$SSH_DIR"
chmod 700 "$SSH_DIR"
chmod 600 "$SSH_DIR/authorized_keys"

echo "==> [4/8] Ghi cấu hình sshd riêng cho user (drop-in, không đụng sshd_config gốc)"
DROPIN_DIR="/etc/ssh/sshd_config.d"
mkdir -p "$DROPIN_DIR"
DROPIN_FILE="$DROPIN_DIR/00-tunnel-${USERNAME}.conf"

# Cộng dồn với danh sách port đã có sẵn trong file cấu hình cũ (nếu có) — 1 user
# tunnel-only thường phục vụ NHIỀU máy đích khác nhau, mỗi máy 1 remote_port
# riêng (key thì đã append từ v1.2.0, nhưng port trước đây vẫn bị GHI ĐÈ hoàn
# toàn mỗi lần chạy). Thêm port cho máy B mà quên gõ lại port máy A đang dùng sẽ
# ÂM THẦM cắt mất tunnel của máy A — bug thật, giờ hợp nhất thay vì thay thế.
EXISTING_PORTS=()
if [[ -f "$DROPIN_FILE" ]]; then
  while read -r tok; do
    [[ "$tok" == 127.0.0.1:* ]] && EXISTING_PORTS+=("${tok#127.0.0.1:}")
  done < <(grep -E '^[[:space:]]*PermitListen[[:space:]]' "$DROPIN_FILE" | sed -E 's/^[[:space:]]*PermitListen[[:space:]]+//' | tr ' ' '\n')
fi

KEPT_FROM_EXISTING=()
for ep in "${EXISTING_PORTS[@]}"; do
  already_listed=0
  for p in "${TUNNEL_PORTS[@]}"; do
    [[ "$p" == "$ep" ]] && { already_listed=1; break; }
  done
  if [[ $already_listed -eq 0 ]]; then
    TUNNEL_PORTS+=("$ep")
    KEPT_FROM_EXISTING+=("$ep")
  fi
done
if [[ ${#KEPT_FROM_EXISTING[@]} -gt 0 ]]; then
  echo "    Giữ nguyên port đã cấp cho máy khác trước đó (không đụng tới): ${KEPT_FROM_EXISTING[*]}"
fi

PERMIT_LISTEN=""
for p in "${TUNNEL_PORTS[@]}"; do
  PERMIT_LISTEN="${PERMIT_LISTEN}127.0.0.1:${p} "
done
PERMIT_LISTEN="${PERMIT_LISTEN% }"
echo "    PermitListen sẽ áp dụng (đã cộng dồn, nếu có): $PERMIT_LISTEN"

if [[ -f "$DROPIN_FILE" ]]; then
  cp "$DROPIN_FILE" "${DROPIN_FILE}.bak.$(date +%Y%m%d%H%M%S)"
fi

cat > "$DROPIN_FILE" <<EOF
# Quản lý bởi vps_setup.sh cho user tunnel "$USERNAME".
# Không sửa tay — chạy lại vps_setup.sh để cập nhật (sẽ ghi đè file này).
ClientAliveInterval 60
ClientAliveCountMax 3

Match User $USERNAME
    PubkeyAuthentication yes
    PasswordAuthentication no
    KbdInteractiveAuthentication no
    AllowTcpForwarding yes
    AllowAgentForwarding no
    AllowStreamLocalForwarding no
    X11Forwarding no
    PermitTunnel no
    GatewayPorts no
    PermitTTY no
    PermitListen $PERMIT_LISTEN
    ForceCommand /usr/sbin/nologin
Match All
EOF
echo "    Đã ghi $DROPIN_FILE (PermitListen: $PERMIT_LISTEN)"

echo "==> [5/8] Kiểm tra xung đột: có file nào khác trong sshd_config.d/ cũng match user này không"
CONFLICT_FOUND=0
for f in "$DROPIN_DIR"/*.conf; do
  [[ -f "$f" ]] || continue
  [[ "$f" == "$DROPIN_FILE" ]] && continue
  [[ "$f" == "$DROPIN_FILE".bak.* ]] && continue
  if grep -qE "^[[:space:]]*Match[[:space:]]+User[[:space:]]+$USERNAME([[:space:]]|\$)" "$f"; then
    CONFLICT_FOUND=1
    echo "" >&2
    echo "CẢNH BÁO: file '$f' cũng có 'Match User $USERNAME'." >&2
    echo "File nào được glob-sort và nạp trước sẽ thắng (thường là file số nhỏ hơn)." >&2
    echo "Nội dung file:" >&2
    echo "----------------------------------------" >&2
    cat "$f" >&2
    echo "----------------------------------------" >&2
  fi
done
if [[ $CONFLICT_FOUND -eq 1 ]]; then
  echo "" >&2
  echo "Script sẽ vẫn tiếp tục và TỰ KIỂM CHỨNG lại cấu hình thực tế ở bước cuối." >&2
  echo "Nếu bước kiểm chứng cuối FAIL, bạn cần tự xử lý (xoá/sửa) file xung đột ở trên." >&2
else
  echo "    Không thấy file nào khác định nghĩa Match User $USERNAME."
fi

echo "==> [6/8] Kiểm tra cú pháp sshd_config"
if ! sshd -t; then
  echo "Lỗi cú pháp! Đang gỡ file vừa tạo để không phá sshd..." >&2
  rm -f "$DROPIN_FILE"
  exit 1
fi

echo "==> [7/8] Restart sshd"
if command -v systemctl &>/dev/null; then
  systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null || true
fi
if ! (systemctl is-active --quiet sshd 2>/dev/null || systemctl is-active --quiet ssh 2>/dev/null); then
  service ssh restart 2>/dev/null || service sshd restart 2>/dev/null || true
fi

echo "==> [8/8] Tự kiểm chứng cấu hình thực tế có hiệu lực hay không"
sleep 1
EFFECTIVE="$(sshd -T -C "user=$USERNAME,host=127.0.0.1,addr=127.0.0.1,laddr=127.0.0.1,lport=22" 2>/dev/null)"
EFF_FORWARD="$(echo "$EFFECTIVE" | awk '/^allowtcpforwarding /{print $2}')"
EFF_PERMITLISTEN="$(echo "$EFFECTIVE" | awk '/^permitlisten /{$1=""; print substr($0,2)}')"
EFF_FORCECMD="$(echo "$EFFECTIVE" | awk '/^forcecommand /{$1=""; print substr($0,2)}')"

echo ""
echo "  AllowTcpForwarding thực tế : $EFF_FORWARD  (cần: yes)"
echo "  PermitListen thực tế       : $EFF_PERMITLISTEN  (cần chứa: $PERMIT_LISTEN)"
echo "  ForceCommand thực tế       : $EFF_FORCECMD"

VERIFY_OK=1
[[ "$EFF_FORWARD" == "yes" ]] || VERIFY_OK=0
# So khớp CHÍNH XÁC từng token (không dùng substring "*...*"): substring có thể
# khớp nhầm, vd cần port "22" nhưng PermitListen chỉ có "127.0.0.1:2222" thì
# "127.0.0.1:22" vẫn là substring của nó -> false positive nếu dùng wildcard.
read -r -a EFF_PERMITLISTEN_ARR <<< "$EFF_PERMITLISTEN"
for p in "${TUNNEL_PORTS[@]}"; do
  FOUND_PORT=0
  for tok in "${EFF_PERMITLISTEN_ARR[@]}"; do
    [[ "$tok" == "127.0.0.1:${p}" ]] && { FOUND_PORT=1; break; }
  done
  [[ $FOUND_PORT -eq 1 ]] || VERIFY_OK=0
done

# Không dùng "awk '{...; exit}'" ở đây: awk thoát sớm trong khi sshd -T vẫn đang ghi
# sẽ khiến sshd -T nhận SIGPIPE (exit 141), và với "set -o pipefail" điều đó làm
# nguyên câu lệnh (và cả script, do set -e) bị coi là lỗi dù không có gì sai thật sự.
CURRENT_SSH_PORT="$(sshd -T 2>/dev/null | awk '/^port / && !found{print $2; found=1}')"
CURRENT_SSH_PORT="${CURRENT_SSH_PORT:-22}"

echo ""
if [[ $VERIFY_OK -eq 1 ]]; then
  echo "✔ HOÀN TẤT — cấu hình đã được xác nhận có hiệu lực thật sự (không chỉ giả định)."
  echo "  - User '$USERNAME' chỉ dùng được để tunnel (không login shell được)."
  echo "  - Port được phép forward: $PERMIT_LISTEN"
  echo "  - Test nhanh từ máy local: ssh -i <private_key> -p $CURRENT_SSH_PORT $USERNAME@<VPS_IP> true"
  echo "    (auth OK thì lệnh trả về ngay với exit code khác 0, KHÔNG bị treo — do tài khoản không có shell)"
  echo ""
  echo "------------------------------------------------------------------------"
  echo "Máy CLIENT (máy sẽ dùng để chạy tunnel/ProxyJump) cần có đúng PRIVATE KEY"
  echo "khớp với public key vừa cài. Tuỳ bạn đã tạo keypair ở đâu, chọn 1 trong 2:"
  echo "------------------------------------------------------------------------"
  echo ""
  echo "  [Phương án A — khuyến nghị] Keypair đã sinh SẴN TRÊN MÁY CLIENT"
  echo "  (vd bằng local_setup.sh, hoặc tự ssh-keygen), rồi bạn dán public key lên"
  echo "  đây. Private key vốn đã nằm đúng chỗ, KHÔNG cần làm gì thêm — private"
  echo "  key không bao giờ nên rời khỏi máy đã sinh ra nó."
  echo "  -> Chỉ cần verify: ssh -i <private_key> -p $CURRENT_SSH_PORT $USERNAME@<VPS_IP> true"
  echo ""
  if [[ -n "$PRIVATE_KEY_ON_VPS_HINT" ]]; then
    echo "  [Phương án B] Phát hiện keypair được sinh NGAY TRÊN VPS này ($PRIVATE_KEY_ON_VPS_HINT)."
    echo "  Nội dung private key (copy TOÀN BỘ, gồm cả dòng BEGIN/END, dán sang máy client):"
    echo "  ---- BEGIN nội dung private key ----"
    cat "$PRIVATE_KEY_ON_VPS_HINT"
    echo "  ---- END nội dung private key ----"
    echo "  Trên máy CLIENT: dán vào ~/.ssh/vps_tunnel rồi:  chmod 600 ~/.ssh/vps_tunnel"
    echo "  Sau khi đã dán và verify xong, XOÁ private key khỏi VPS (không để tồn tại ở 2 nơi):"
    echo "    shred -u $PRIVATE_KEY_ON_VPS_HINT 2>/dev/null || rm -f $PRIVATE_KEY_ON_VPS_HINT"
  else
    echo "  [Phương án B] Nếu keypair được sinh NGAY TRÊN VPS này (vd chạy ssh-keygen"
    echo "  trực tiếp tại đây thay vì trên client) — cần TẢI private key đó về máy"
    echo "  client qua kênh đã mã hoá (scp/sftp), rồi XOÁ khỏi VPS (không nên để"
    echo "  private key tồn tại ở 2 nơi lâu dài). Chạy từ máy CLIENT:"
    echo "    scp $USER@<VPS_IP>:<đường_dẫn_private_key_trên_VPS> ~/.ssh/vps_tunnel"
    echo "    chmod 600 ~/.ssh/vps_tunnel"
    echo "  Sau khi đã tải và verify xong, xoá private key khỏi VPS:"
    echo "    shred -u <đường_dẫn_private_key_trên_VPS> 2>/dev/null || rm -f <đường_dẫn_private_key_trên_VPS>"
  fi
  echo "------------------------------------------------------------------------"
else
  echo "✘ CẢNH BÁO — cấu hình KHÔNG có hiệu lực như mong đợi, khả năng cao do 1 file khác" >&2
  echo "  trong /etc/ssh/sshd_config.d/ đang đè lên (xem cảnh báo xung đột ở bước 4/7 nếu có)." >&2
  echo "  Kiểm tra thủ công: sudo sshd -T -C user=$USERNAME,host=127.0.0.1,addr=127.0.0.1,laddr=127.0.0.1,lport=22 | grep -iE 'allowtcpforwarding|permitlisten'" >&2
  exit 1
fi
