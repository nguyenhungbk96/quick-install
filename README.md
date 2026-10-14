# quick-install

Kho script cài đặt nhanh bằng 1 dòng lệnh `curl`.

## Danh sách công cụ

| Công cụ | Mục đích | Hướng dẫn chi tiết |
| :--- | :--- | :--- |
| **[ssh-tunnel](ssh-tunnel/README.md)** | SSH từ **Máy Client** vào **Máy Local** (sau NAT/WSL/CGNAT) thông qua **Máy VPS** có IP public | [Xem hướng dẫn](ssh-tunnel/README.md) |

---

## Cài đặt nhanh: `ssh-tunnel`

Mô hình gồm **3 máy**: **Máy Local** (server đích cần SSH vào) ↔ **Máy VPS** (trạm trung gian có IP public) ↔ **Máy Client** (laptop bạn ngồi gõ lệnh).

### Bước 1 — Trên Máy Local (Khởi tạo Key & Mở Tunnel)

Chạy bằng user hiện tại:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/nguyenhungbk96/quick-install/main/ssh-tunnel/local_setup.sh)"
```

Hoặc chạy bằng `root` (trên server không có người đăng nhập trực tiếp):

```bash
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/nguyenhungbk96/quick-install/main/ssh-tunnel/local_setup.sh)"
```

- Nhấn **Enter** để tạo SSH key.
- **Copy dòng Public Key** in trên màn hình và giữ nguyên cửa sổ terminal này.

### Bước 2 — Trên Máy VPS (Tạo User Tunnel & Mở Port)

```bash
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/nguyenhungbk96/quick-install/main/ssh-tunnel/vps_setup.sh)"
```

- Nhập **tên user tunnel** (vd: `jump` hoặc Enter dùng mặc định `tunneluser`).
- Dán **Public Key** vừa copy ở Bước 1.
- Nhập **port mở trên VPS** (vd: `2223`).
- Xong Bước 2, quay lại cửa sổ **Máy Local** nhấn **Enter**, nhập **IP VPS**, **tên user tunnel**, và **Port map** (vd: `2223:22`).

### Bước 3 — Trên Máy Client (Kết nối)

Mở terminal trên **Máy Client**, copy-paste lần lượt **3 lệnh in sẵn ở cuối màn hình Máy Local** (chép private key, thêm `~/.ssh/config`, và gõ `ssh home`).

👉 Xem đầy đủ cách thêm nhiều máy, thêm user và xử lý lỗi tại **[ssh-tunnel/README.md](ssh-tunnel/README.md)**.
