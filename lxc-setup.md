# 🖥️ Konfiguracja kontenera LXC na Proxmox (LXC Container Setup on Proxmox)

> **Wykonaj na hoście Proxmox PRZED uruchomieniem `install.sh` w kontenerze!**  
> *Run on the Proxmox host BEFORE running `install.sh` inside the container!*

---

## Szybka konfiguracja przez GUI (Quick Setup via GUI)

### 1. Pobierz szablon Debian 13 Trixie (Download the Debian 13 Trixie Template)

W GUI Proxmox: **Datacenter → [nazwa noda] → local → CT Templates → Templates → Download**  
*In Proxmox GUI: **Datacenter → [node name] → local → CT Templates → Templates → Download***

Wyszukaj `debian-13` i pobierz najnowszy szablon.  
*Search for `debian-13` and download the latest template.*

> **Jeśli nie widzisz Debiana 13 (If you don't see Debian 13):** zaktualizuj listę szablonów / update the template list:  
> `pveam update` (na hoście Proxmox / on the Proxmox host)

---

### 2. Stwórz kontener (Create the Container)

**Create CT** i wypełnij kolejne zakładki / *and fill in the following tabs*:

| Zakładka (Tab) | Ustawienie (Setting) | Wartość (Value) |
|---|---|---|
| **General** | CT ID | Dowolne wolne ID / Any free ID, np. `152` |
| | Hostname | `firecrawl` (lub dowolna nazwa / or any name) |
| | Unprivileged | ✅ **ZAZNACZONE / CHECKED** (ważne / important!) |
| | Password | Ustaw silne hasło roota / Set a strong root password |
| **Template** | Storage | `local` |
| | Template | `debian-13-trixie-standard` |
| **Disks** | Root disk | Min. **60 GB** (zalecane / recommended 100 GB) |
| **CPU** | Cores | Min. **4** (zalecane / recommended 8) |
| **Memory** | Memory | Min. **8192 MB** (8 GB) |
| | Swap | Min. **2048 MB** (2 GB) |
| **Network** | Bridge | `vmbr0` |
| | IPv4/CIDR | **Ustaw IP pasujące do Twojej sieci / Set IP matching your network**, np. `192.168.1.100/24` |
| | Gateway | **Brama Twojej sieci / Your network gateway**, np. `192.168.1.1` |

---

### 3. 🔑 KLUCZOWE — Włącz nesting + keyctl dla Dockera! (CRITICAL — Enable Nesting + Keyctl for Docker!)

**Bez tego Docker NIE wystartuje w kontenerze LXC!**  
*Without this, Docker WILL NOT start in the LXC container!*

Na hoście Proxmox wykonaj / *On the Proxmox host, run* (zastąp `<CTID>` numerem swojego kontenera / *replace `<CTID>` with your container number*):

```bash
# Edytuj plik konfiguracyjny kontenera / Edit the container config file
nano /etc/pve/lxc/<CTID>.conf
```

Dodaj na końcu pliku / *Add at the end of the file*:

```
features: keyctl=1,nesting=1
```

...lub jednym poleceniem / *...or with a single command*:

```bash
pct set <CTID> -features keyctl=1,nesting=1
```

---

### 4. Uruchom kontener i wejdź do niego (Start the Container and Enter It)

```bash
pct start <CTID>
pct enter <CTID>
```

Teraz jesteś w środku kontenera — możesz uruchomić `install.sh`!  
*Now you're inside the container — you can run `install.sh`!*

---

## Alternatywnie: pełna konfiguracja z linii poleceń (Alternative: Full CLI Configuration)

```bash
# ⚠️ DOSTOSUJ TE ZMIENNE DO SWOJEJ SIECI I ZASOBÓW!
# ⚠️ ADJUST THESE VARIABLES TO YOUR NETWORK AND RESOURCES!

# 1. Pobierz szablon / Download template
pveam update
TEMPLATE=$(pveam available | grep debian-13 | awk '{print $2}' | head -1)
pveam download local $TEMPLATE

# 2. Ustaw zmienne / Set variables (DOSTOSUJ! / ADJUST!)
CTID=152                           # dowolne wolne ID / any free ID
STORAGE="local-lvm"                # sprawdź nazwę storage / check storage name: pvesm status
IP_CIDR="192.168.1.100/24"         # DOSTOSUJ do swojej sieci! / ADJUST to your network!
GATEWAY="192.168.1.1"              # DOSTOSUJ do swojej sieci! / ADJUST to your network!
PASSWORD="USTAW_SILNE_HASLO"       # DOSTOSUJ! / ADJUST! (SET_STRONG_PASSWORD)

# 3. Stwórz kontener / Create container
pct create $CTID "local:vztmpl/$TEMPLATE" \
    --hostname firecrawl \
    --storage $STORAGE \
    --rootfs ${STORAGE}:80 \
    --cores 8 \
    --memory 8192 \
    --swap 4096 \
    --net0 name=eth0,bridge=vmbr0,ip=${IP_CIDR},gw=${GATEWAY} \
    --unprivileged 1 \
    --password "$PASSWORD" \
    --features keyctl=1,nesting=1 \
    --onboot 1

# 4. Uruchom / Start
pct start $CTID
pct enter $CTID
```

---

## Weryfikacja przed instalacją (Pre-Installation Verification)

W kontenerze sprawdź / *Inside the container, verify*:

```bash
# Czy nesting działa? / Does nesting work?
ls /proc/sys/net/ipv4/ | head -5
# Powinno pokazać listę plików, NIE "Permission denied"
# Should show a file list, NOT "Permission denied"

# Czy keyctl działa? / Does keyctl work?
cat /proc/keys
# Powinno pokazać listę kluczy (nawet pustą)
# Should show a key list (even if empty)

# Czy jest internet? / Is there internet access?
ping -c 1 google.com

# Ile RAM? / How much RAM?
free -h
```

---

## Rozwiązywanie problemów (Troubleshooting)

| Problem | Rozwiązanie (Solution) |
|---|---|
| Nie widzę `debian-13` w szablonach / Don't see `debian-13` in templates | `pveam update` na hoście Proxmox / on the Proxmox host |
| `features: keyctl=1` nie działa / doesn't work | Upewnij się, że używasz **unprivileged** kontenera / Make sure you're using an **unprivileged** container |
| Docker nie startuje po instalacji / Docker won't start after installation | Sprawdź / Check: `grep features /etc/pve/lxc/<CTID>.conf` — musi być / must contain `keyctl=1,nesting=1` |
| `Permission denied` przy `docker run` / with `docker run` | Zrestartuj kontener po dodaniu `keyctl=1,nesting=1` / Restart the container after adding `keyctl=1,nesting=1` |
| Brak miejsca / Out of space | Rozszerz dysk w GUI Proxmox (Resources → Resize disk) / Expand disk in Proxmox GUI (Resources → Resize disk) |

---

## ⚠️ Ważne uwagi (Important Notes)

1. **Kontener LXC NIE jest VM** — używa kernela hosta. Docker działa, ale ma ograniczenia.  
   *An LXC container is NOT a VM — it uses the host kernel. Docker works, but has limitations.*

2. **Unprivileged + nesting + keyctl** to minimum żeby Docker działał.  
   *Unprivileged + nesting + keyctl is the minimum for Docker to work.*

3. **Dla produkcji** rozważ VM zamiast LXC — lepsza izolacja, mniej problemów.  
   *For production*, consider a VM instead of LXC — better isolation, fewer issues.

4. **Debian 13 Trixie** jest wspierany przez Dockera oficjalnie (od wersji 2025+).  
   *Debian 13 Trixie* is officially supported by Docker (since version 2025+).

5. **Firewall Proxmox** — port 3002 musi być dostępny z sieci LAN (chyba że używasz NAT).  
   *Proxmox Firewall* — port 3002 must be accessible from the LAN (unless using NAT).

6. **Sprawdź nazwę storage / Check storage name**: przed użyciem CLI sprawdź / before using CLI check `pvesm status` — może to być / it could be `local`, `local-lvm`, `local-zfs` itp.

---

Po wykonaniu powyższych kroków, przejdź do `install.sh` w kontenerze.  
*After completing the above steps, proceed to `install.sh` inside the container.*
