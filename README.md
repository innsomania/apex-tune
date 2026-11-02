# ApexTune

**Experimental Intel Mac package-power controller for macOS.**

[English](#english) · [Türkçe](#türkçe)

## English

### What it does

ApexTune adjusts Intel package power limits to make power transitions more gradual and reduce sustained heat. It adds a controller alongside macOS power management; Apple's frequency, fan and thermal protections remain active.

The package limit is an allowance, not a power-consumption target. A 10 W limit does not require the CPU to consume 10 W: measured package power can fall directly from 9 W to 4 W when work ends. PL1/PL2 do not measure the whole laptop or the discrete Radeon GPU.

**Status:** experimental, locally built and unsigned. Protocol v4 and half-watt readback were exercised on one MacBookPro15,1 running macOS Sequoia 15.8.2. This is not broad hardware certification, a benchmarked efficiency improvement, a guarantee of smoothness, or a guarantee that temperature stays below 85 °C. Undervolting is not implemented.

### Compatibility and prerequisites

| Item | Current scope |
| --- | --- |
| Hardware | GenuineIntel family 6, model `0x9e`; runtime allowlist |
| Device used for live verification | 15-inch 2019 MacBook Pro, Core i9, Radeon Pro 560X |
| OS build target | Intel x86_64, macOS 15 or later; live verification on 15.8.2 |
| Toolchain used | Xcode 26.3, Swift 6.2.4, macOS SDK 26.2 |
| Privileged component | Unsigned IOKit kernel extension; matching v4 driver and client required |
| Not supported by this implementation | Apple silicon, separate Radeon power control, fan control, voltage offsets |

The unsigned kernel extension needs host security settings that permit loading it, administrator authorization, and possibly system approval and a restart. These are separate from enabling the app. SIP is a security feature, not Apple's thermal-management switch. This repository does not supply a signed/notarized installer or an unattended method to bypass macOS approval.

### Power policy

- PL1 targets: **10–80 W in 0.5 W steps**: 141 supported values.
- Ordinary increases **and** decreases: at most **0.5 W per confirmed update**, at least **3 seconds apart**, for both PL1 and PL2. Scheduling can make intervals longer.
- Requests use integer half-watt units internally. The driver checks exact representation using the CPU's RAPL power unit; unsupported encodings are rejected rather than rounded.
- All applied targets stay at or below 80 W and the session-start limits. Returning to the saved baseline can restore values above 80 W.
- Five protocol tiers permit PL2 headroom of 0/5/10/15/20 W. The automatic controller further restricts extra headroom to **at most 5 W**, with a **2-second target burst window** and **30-second cooldown**. This is a power budget, not a direct CPU Turbo-frequency switch. The one-second control loop and OS scheduling are not a hard real-time deadline.
- Extra PL2 headroom is allowed only below **75 °C CPU die temperature**, subject to the gradual ramp and cooldown.
- At **75 °C** or serious macOS thermal pressure, PL1 is capped at **25 W**, with PL2 equal to PL1. At **80 °C**, the safety target is **10/10 W**.
- Thermal protection, sensor fallback and burst closure can reduce power immediately; they override the ordinary gradual decrease.
- Stale/missing required sensors or critical thermal pressure select **10/10 W** while the driver connection is healthy. Recovery requires at least five fresh, safe samples spanning ten seconds. Sensor collection has bounded retry delays.

The policy starts from aggregate CPU load, CPU die temperature, estimated Intel package power and macOS thermal state. It does not measure application-specific responsiveness. With the fixed ramp, 10→30 W takes at least two minutes and 10→80 W at least seven minutes, which can limit bursty workloads.

### Architecture and failure behavior

```text
powermetrics + CPU load + thermal state
                  |
       root LaunchDaemon (--daemon)
                  |
     bundled probe CLI / IOKit connection
                  |
   ApexTunePowerReader v4 -> package PL1 / PL2

root-owned status.json -> user menu icon (--status)
```

The root service owns a single controller lease. The menu runs in the user's Aqua session and reads status; it has no user-writable command channel. Status is atomically written under a root-owned directory. Old or missing temperature/power samples are displayed as unavailable.

The driver exposes fixed package-power operations, checks privileged access and preserves unrelated register bits. Heartbeats renew a 30-second lease every ten seconds. Explicit shutdown, client loss or watchdog expiry attempts to restore the original PL1/PL2 fields and verifies readback. Failed restoration is reported; it is not presented as success. A broken transport can therefore restore the original higher limits: **80 W is not a permanent firmware cap**.

### Build and test

```sh
git clone https://github.com/innsomania/apex-tune.git
cd apex-tune
make -C probe test
make -C app test
```

Outputs:

- `probe/build/ApexTunePowerReader.kext`
- `probe/build/apextune-power-probe`
- `app/build/ApexTune.app`

These commands compile and run offline tests; they do not install a driver or change device power limits. Tests cover exact half-watt encoding, bounds, malformed inputs, baseline restoration, gradual changes in both directions, sensor fallback, burst limits, status freshness, singleton behavior and launchd configuration. Offline tests cannot prove hardware loading, long-term thermal behavior or energy savings.

Safe offline simulation:

```sh
app/build/ApexTune.app/Contents/MacOS/ApexTune --simulate
```

### Install and start

This is an advanced local installation, not a general-purpose consumer installer. Review the source and hardware allowlist before loading kernel code.

1. Build and pass the checks above.
2. On a compatible host whose security policy permits the unsigned extension, install the matching v4 driver with administrator privileges:

   ```sh
   sudo ditto probe/build/ApexTunePowerReader.kext /Library/Extensions/ApexTunePowerReader.kext
   sudo chown -R root:wheel /Library/Extensions/ApexTunePowerReader.kext
   sudo chmod -R go-w /Library/Extensions/ApexTunePowerReader.kext
   sudo kmutil load -p /Library/Extensions/ApexTunePowerReader.kext
   ```

3. Complete any macOS approval/restart it requests. Do not treat copying the bundle as proof it loaded. Verify the loaded version and readback:

   ```sh
   kmutil showloaded --list-only | grep com.apextune.PowerReader
   sudo probe/build/apextune-power-probe
   ```

4. With the matching v4 driver available, install autostart:

   ```sh
   sudo deployment/install.sh
   ```

The deployment script installs the app, root LaunchDaemon and per-user LaunchAgent. **It does not install or approve the kernel extension.** Quit a legacy interactive `--control` session before using it. The daemon starts at boot; the menu icon starts at Aqua login. Updates to existing launchd jobs may require waiting for shutdown before bootstrapping again; check errors and service state rather than assuming installation succeeded.

### Check operation

```sh
sudo launchctl print system/com.apextune.controller
launchctl print "gui/$(id -u)/com.apextune.status"
cat '/Library/Application Support/ApexTune/status.json'
tail -n 30 /Library/Logs/ApexTune/controller.log
```

Look for a running service, fresh sensor timestamps and confirmed limit changes. `Package power` is estimated consumption; `Actual limits` is the hardware limit readback. JSON `appliedPL1` and `appliedPL2` are **integer half-watt units**; `actualPL1` and `actualPL2` are watts. For example, `appliedPL1: 21` means 10.5 W.

Launching the app without flags selects observation only. `--status` reads the daemon status. `sudo .../ApexTune --control` starts an explicit interactive controller; it cannot share the controller lock with the daemon. Avoid starting a second controller to test an already active service.

### Remove autostart

```sh
sudo deployment/uninstall.sh
```

This unloads/removes the launchd jobs and status file, retaining the app and logs. It **does not remove the kernel extension or re-enable SIP**. Removing autostart also removes the daemon's ongoing limits; saved original limits are restored when cleanup succeeds. Full driver removal/security-policy restoration must be handled separately for that host.

### Repository access and notices

Public visibility does not grant push access. Only the owner or explicitly authorized writers can change this repository. Forks and pull requests do not write directly to its branches. Personal conversations, device screenshots and raw system archives are excluded from the public source history.

Apple XNU glue files retain their Apple Public Source License notices; see [provenance](probe/APPLE_XNU_PROVENANCE.md). No general license for the original ApexTune code has been selected in this repository. Public visibility alone is not a permissive software license.

## Türkçe

### Ne yapar?

ApexTune, Intel Mac'in işlemci paket güç sınırlarını değiştirerek güç geçişlerini yumuşatmayı ve sürekli ısınmayı azaltmayı amaçlayan deneysel bir macOS uygulamasıdır. Apple'ın güç yönetiminin üzerine çalışır; fan, frekans ve termal korumaları kapatmaz.

**Güç sınırı ile tüketim farklıdır.** Sınır 10 W iken işlemci 9 W veya 4 W tüketebilir. İş bitince tüketimin aniden düşmesi normaldir; 0,5 W kuralı gerçek tüketimi sabitlemez, izin verilen sınırı değiştirir. Paket ölçümü tüm bilgisayarın veya ayrı Radeon GPU'nun tüketimi değildir.

### Destek ve mevcut durum

- Çalışma kapsamı: GenuineIntel aile 6 / model `0x9e`, Intel x86_64 ve macOS 15+ hedefi.
- Canlı doğrulama: 2019 15 inç MacBook Pro, Core i9 / Radeon Pro 560X, Sequoia 15.8.2.
- Kullanılan derleme araçları: Xcode 26.3, Swift 6.2.4, SDK 26.2.
- Sürücü ve istemcinin ikisi de **v4** olmalı; eski sürümlerle karışık kullanım desteklenmez.
- Apple silicon, ayrı Radeon watt kontrolü, fan kontrolü ve undervolt uygulanmıyor.
- İmzalı/noter onaylı bir tüketici kurulum paketi değildir. İmzasız çekirdek sürücüsü için uygun güvenlik ayarları, yönetici onayı ve gerektiğinde yeniden başlatma gerekir.

Tek cihazda doğrulanmış deneysel yazılımdır. Daha iyi performans/enerji verimliliği, kusursuz akıcılık veya **85 °C'nin hiç aşılmaması garanti edilmez**. SIP güvenlik korumasıdır; Apple'ın termal yönetimiyle aynı şey değildir.

### Güç yönetimi kuralları

| Kural | Davranış |
| --- | --- |
| Güç seviyeleri | 10–80 W, 0,5 W aralıkla 141 değer |
| Normal artış ve düşüş | Onaylanan her adımda en fazla 0,5 W; adımlar arasında en az 3 saniye |
| Kısa süreli ek güç | Otomatik modda en fazla +5 W; 2 saniyelik hedef pencere, ardından 30 saniye bekleme |
| Ek gücün sıcaklık koşulu | CPU die sıcaklığı 75 °C'nin altında olmalı |
| 75 °C veya serious termal durum | En fazla 25 W, PL2 = PL1 |
| 80 °C | Gecikmesiz 10/10 W güvenlik hedefi |
| Sensör verisi eksik/eski veya critical durum | Sağlıklı sürücü bağlantısıyla 10/10 W korunur |
| Sensör sonrası toparlanma | En az beş taze/güvenli örnek, en az 10 saniye |
| Ana sınır | Uygulanan hedeflerde en fazla 80 W ve oturum başlangıç sınırları |

Güvenlik düşüşleri ve kısa atağın kapanışı normal doğrusal azalmayı geçersiz kılabilir. Bir saniyelik kontrol döngüsü ve işletim sistemi zamanlaması nedeniyle süreler kesin gerçek zaman garantisi değildir. Kademeler Turbo frekansını doğrudan açıp kapatmaz; PL2 güç bütçesini belirler.

Yavaş geçişin performans bedeli vardır: 10 W'tan 30 W'a çıkış en az iki dakika, 80 W'a çıkış en az yedi dakika sürer. Yoğun işlerde işlemci bu sırada sınırlandırılabilir. Uygulama, hangi programın akıcılığa duyarlı olduğunu doğrudan ölçmez.

### Yapı ve hata davranışı

Root arka plan servisi ölçümleri toplar ve IOKit üzerinden paket sınırlarını yazar. Kullanıcı oturumundaki menü simgesi yalnızca root tarafından yazılan durum dosyasını okur. Sensör ve servis zaman damgaları ayrı izlenir; eski sıcaklık ölçümü güncelmiş gibi gösterilmez.

Sürücü tek denetleyici oturumu kabul eder; her ayrıcalıklı işlemde yetki kontrol edilir. İlgisiz MSR bitleri korunur ve yazım sonrası geri okuma yapılır. 10 saniyede bir bağlantı yenilenir; 30 saniyelik çekirdek zaman aşımı vardır.

Normal kapanış, bağlantı kaybı veya watchdog durumunda başlangıç güç alanları geri yüklenmeye çalışılır. Başlangıç sınırları 80 W'tan yüksek olabilir. Dolayısıyla **80 W kalıcı firmware sınırı değildir**. Geri yükleme başarısızsa hata bildirilir. Sensör kesintisi sırasında bağlantı sağlıklıysa kontrolü bırakmak yerine 10/10 W korunur.

### Derleme, kurulum ve kullanım

```sh
git clone https://github.com/innsomania/apex-tune.git
cd apex-tune
make -C probe test
make -C app test
```

Bu komutlar donanım ayarı değiştirmez. Uygulama `app/build/ApexTune.app`, sürücü `probe/build/ApexTunePowerReader.kext` altında oluşur. Donanıma erişmeyen simülasyon:

```sh
app/build/ApexTune.app/Contents/MacOS/ApexTune --simulate
```

Kurulum sırası: yukarıdaki [Install and start](#install-and-start) bölümündeki komutlarla eşleşen v4 sürücüyü kur/yükle, macOS'un istediği onay veya yeniden başlatmayı tamamla, yüklü sürümü doğrula, ardından:

```sh
sudo deployment/install.sh
```

Bu betik sürücüyü kurmaz; uygulama ile otomatik başlatma görevlerini kurar. Kontrol servisi açılışta, menü simgesi kullanıcı oturumunda başlar. Önceden elle açılmış `--control` oturumunu kapat. Kurulum hata verirse servis durumunu kontrol et; yalnızca dosya kopyalanması etkin çalışmanın kanıtı değildir.

Kontrol:

```sh
sudo launchctl print system/com.apextune.controller
launchctl print "gui/$(id -u)/com.apextune.status"
cat '/Library/Application Support/ApexTune/status.json'
tail -n 30 /Library/Logs/ApexTune/controller.log
```

Menüde `Package power` tahmini tüketim, `Actual limits` donanımdan geri okunan sınırlardır. Durum JSON'undaki `appliedPL1`/`appliedPL2` yarım watt birimindedir: 21 değeri 10,5 W demektir. `actualPL1`/`actualPL2` doğrudan watt değeridir.

Otomatik başlatmayı kaldırmak için:

```sh
sudo deployment/uninstall.sh
```

Uygulama ve kayıtlar kalır; sürücü kaldırılmaz, SIP yeniden açılmaz. Servis kapanınca başlangıç limitlerine dönüş denenir. Sürücünün kaldırılması ve güvenlik ayarlarının eski haline getirilmesi ayrıca ele alınmalıdır.

### Doğrulama ve erişim

Testler yarım watt kodlamasını, sınırları, hatalı girişleri, iki yönlü geçiş hızını, sıcaklık/sensör davranışını, kısa güç atağını, eski veri gösterimini ve otomatik başlatma yapılandırmasını kapsar. Canlı kayıtlarda v4 sürücü, açılışta servis başlangıcı ve 0,5 W geri okuma doğrulanmıştır. Uzun süreli kararlılık, tüm cihazlarda destek ve karşılaştırmalı tasarruf kanıtlanmış değildir.

Public repo herkese okuma imkânı verir; yazma yetkisi vermez. Repoyu yalnızca sahibi ve açıkça yetkilendirilmiş hesaplar değiştirebilir. Fork veya PR doğrudan bu repoya push yetkisi sağlamaz. Kişisel sohbetler, cihaz ekran görüntüleri ve ham sistem arşivleri public kaynak geçmişine dahil edilmez.

Apple XNU başlangıç dosyalarının lisans bildirimleri korunur: [kaynak bilgisi](probe/APPLE_XNU_PROVENANCE.md). ApexTune'un özgün kodu için genel bir lisans henüz seçilmemiştir; public olmak tek başına serbest kullanım lisansı anlamına gelmez.
