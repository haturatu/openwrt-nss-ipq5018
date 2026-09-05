# IPQ5018 NSS production and Wi-Fi experiment design

このリポジトリは、`qosmio/openwrt-ipq` の `25.12-nss` を基礎に、公式
OpenWrt `openwrt-25.12` の先端へ追従したIPQ5018 NSS bring-up用の作業ツリーです。
NSS関連コードとfirmwareはOpenWrt upstreamには含まれないため、qosmioの
`nss-packages` feedを固定して利用します。

## 2026-09-02時点の実測（NSS無効baseline）

対象機は純正firmwareではなく、公式OpenWrt 25.12.5を起動しています。

| 項目 | 実測値 |
| --- | --- |
| model | Linksys MX2000 |
| compatible | `linksys,mx2000`, `qcom,ipq5018` |
| OpenWrt | 25.12.5 / r33051-f5dae5ece4 |
| Linux | 6.12.94 |
| target | `qualcommax/ipq50xx` |
| Ethernet dataplane | `qca_nss_dp` と `qca_ssdk` がロード済み |
| NSS core | baselineでは `qca_nss_drv` 未ロード |
| ECM | baselineでは `qca_nss_ecm` 未ロード |
| NSS firmware | `/lib/firmware/qca-nss*.bin` は未配置 |
| 外部switch | QCA8337、CPU port 6、SGMII固定1Gbps |
| NSS-DP | `dp2`、register `0x39d00000`、GIC SPI 141、Linux IRQ 43 |

MX2000イメージでは、`dp2`/QCA8337経路を保ったままNSS core用の
`nss-common`/`nss0`とfirmware load用の`nss_region`を追加します。
`qca-nss-drv`は実機で確認済みの通常autoloadへ戻し、ECMは引き続き自動起動
しません。`nss-ipq5018-manual`はdescriptor配置のA/B試験と復旧用に残します。

現在の設定ではOpenWrt標準のsoftware/hardware flow offloadは無効です。NSSの
測定時もこの状態を維持し、NSSと標準flow offloadの二重適用を避けます。

## 採用した構成

```text
official openwrt-25.12
        |
        +-- qosmio NSS kernel/mac80211 patches
        +-- IPQ5018 NSS DT and reserved memory
        +-- nss-packages:NSS-12.5-K6.x
        |
        +-- MX2000
             dp2 -- SGMII -- QCA8337 CPU port 6 -- WAN/LAN
```

NSS firmwareは最初のbring-upでは11.4を選びます。IPQ5018用のmedium memory
profile、firmware load address `0x40000000`、16 MiBのno-map reserved memoryは
qosmio側のIPQ5018定義を使用します。これらはQSDK由来の非upstream仕様なので、
firmwareの起動ログが取れるまで「動作済み」とは扱いません。

通常seedでは `ATH11K_NSS_SUPPORT` を無効化します。2.4 GHz/5 GHzのath11kを
通常経路で動かしたまま、有線NSSとECMを検証するためです。Wi-Fi NSSは、
`nss-setup/enable-ipq5018-wifi-nss.sh`またはworkflow_dispatchの明示入力でだけ
有効化する実験機能です。

## 実装レイヤ

1. `target/linux/qualcommax/files/arch/arm64/boot/dts/qcom/ipq5018-nss.dtsi`
   - IPQ5018 NSS0、clock、IRQ、load address、機能フラグを定義。
2. `target/linux/qualcommax/patches-6.12/*ipq5018*reserved-memory*`
   - firmware領域 `0x40000000..0x41000000` をLinuxから予約。
3. `target/linux/qualcommax/Makefile`
   - qualcommaxの標準パッケージへNSS driver/ECM/bridge managerを追加。
4. `feeds.conf.default`
   - `qosmio/nss-packages` の `NSS-12.5-K6.x` を利用。
5. `nss-setup/config-ipq5018.seed`
   - MX2000を含むIPQ5018向けの再現可能な初期構成。

## 検証段階

### Phase 0: baseline

NSSを有効にしない公式OpenWrt相当で、起動、WAN/LAN、QCA8337、2.4 GHz、5 GHz、
sysupgrade、dual partitionを確認します。

### Phase 1: NSS core autoload

`nss-firmware-ipq50xx` と `kmod-qca-nss-drv`はイメージに含まれ、driverは通常の
kmodloader autoloadで起動します。ECMのautostartだけは無効です。起動後に、
手動modprobeなしで次を確認します。

```text
lsmod | grep qca_nss_drv
cat /proc/sys/dev/nss/general/redirect
grep -i nss /proc/interrupts
dmesg | grep -Ei 'nss|firmware|qca'
```

自動起動の一括判定は、MX2000上で次を実行します。

```sh
sh /tmp/verify-ipq5018-nss-boot.sh
```

複数回reboot試験では、各起動後にこの検証を実行し、NSS core boot、`eth0` link、
WAN DHCP/IPv6を記録します。スクリプトはリポジトリの
`nss-setup/verify-ipq5018-nss-boot.sh`をMX2000の`/tmp`へコピーして使います。
実機なしでrebootを実行するCIにはしていません。

SSH後のA/Bテストは、再起動を挟んで別々に実施します。

```sh
nss-ipq5018-manual status
nss-ipq5018-manual normal

# 別の起動で実施するGMAC1 descriptor配置テスト
nss-ipq5018-manual gmac1-sdram
```

`normal`はfirmware既定の配置、`gmac1-sdram`は
`gmac_tx_desc_1`/`gmac_rx_desc_1`だけをSDRAMへ変更します。各テスト直後に
`dmesg`, `ip link`, `ip addr show`, WAN疎通、`/proc/interrupts`を保存します。overrideで
module parameterが受け付けられない場合は、コマンドが失敗するため、その結果を
成功扱いにしません。firmware load、NSS core 0 initialized、driver probe完了が
得られた後に、GMAC1/`dp2`のlinkが維持されるかを判定します。

ECMは初期状態で無効です。NSS core/DMAの状態が確定した後、次で明示的に有効化
できます。

```sh
nss-ipq5018-manual normal
nss-ipq5018-manual ecm-on
nss-ipq5018-manual ecm-status
```

`ecm-on`はNSS driverがロード済みの場合だけ、NSS frontendを選択してECMを起動
します。driver未ロード時にECMが依存関係からdriverを自動ロードしないよう、init
scriptにもガードを入れています。停止・次回起動無効化は次で行います。

```sh
nss-ipq5018-manual ecm-off
```

直接UCIを操作する場合は、同じ意味になるよう次を実行します。

```sh
uci set ecm.global.acceleration_engine='nss'
uci set ecm.global.enable='1'
uci commit ecm
/etc/init.d/qca-nss-ecm start
```

標準のsoftware/hardware flow offloadは引き続き無効にし、ECM開始後はLAN端末から
WANへトラフィックを流して、ECM/NSSのcounterを確認します。ECMの有効化だけでは
NSS forwarding成功とは判定せず、`ecm_dump.sh`で `ae_interface_identifier` が
`-1` ではないこと、connectionが `accelerated` へ遷移すること、accelerated
counterとNSS statisticsが増加することを確認します。

ECMのNSS interface解決は、DSA user portをMX2000固有の番号へ置き換えません。
`wan`/`lanX` のようなDSA user portで直接NSS interfaceが見つからない場合だけ、
Linux 6.12のDSA APIでconduit（MX2000では `eth0`）を取得し、NSS-DPが登録した
conduitのinterface番号を使います。カーネルログの
`DSA/NSS interface resolve` が `ae_ifnum` を有効値で出すことが、ルール生成前の
診断条件です。

SSDK notifierでは、QCA8337のDSA user portをIPQ5018 MP PHYとして扱わないように
しています。QCA8337のリンク管理はLinux DSA/qca8kに任せ、SSDKの未登録PHYが
port 0へ変換される通知エラーを防ぎます。これはECMのconduit解決とは独立した
修正です。

失敗時はreserved memory、load address、clock/reset、IRQ、firmware ABI、GMAC1
descriptor配置の順に切り分けます。

診断スクリプトはBusyBoxの `ip` 実装に合わせて `ip link` と `ip addr show` を
使います。`nss-setup/diagnose-ipq5018.sh` はNSS module parameter、NSS sysctl、
ECM debugfsのファイル一覧と主要counter、UBI/NSS/UTCM/GMAC関連clockを収集します。

### Phase 2: NSS-DP and QCA8337

`dp2`をQCA8337 uplinkとして扱い、WAN/LANのリンク、VLANなしのIPv4 forwarding、
iperf3の双方向通信を確認します。`dp2`を物理WANと誤認してネットワーク構成を
変更しません。

### Phase 3: ECM NAT44

IPv4 TCP/UDPのroutingとNAT44だけを対象にECM offloadを有効化します。accelerated
connection数とNSS statisticsが増え、CPU負荷が下がることを確認します。

### Phase 4: experimental ath11k Wi-Fi NSS

Wi-Fi NSSは既定イメージへ混ぜず、明示的な実験フラグで有効化します。
これは現在のath11k NSS patch、qca-nss-drv WIFIOFFLOAD、QCN6122 priority、
256 MiB ath11k/pbuf profile、CMN PLL boot fix、Wi-Fi NSS専用の
`clk_ignore_unused pd_ignore_unused`を同時に組み込む構成です。Meshとmac80211
`nss_redirect`は有効化しません。後者のbootargsは診断用で、通常イメージには入りません。

手動ビルドでは、まず通常seedをコピーしてからopt-inします。

```sh
cp nss-setup/config-ipq5018.seed .config
nss-setup/enable-ipq5018-wifi-nss.sh --mem-profile 256
make defconfig
```

MX2000はLinuxから約416 MiBしか見えないため、bring-up中は256Mだけを許可します。
helperとGitHub Actionsは512M/1024Mを明示的に拒否し、ath11kのビルドprofileと
`/etc/config/pbuf`を必ず`256M`/`256mb`へ揃えます。通常のpush buildはWi-Fi NSSを
無効にしたままです。

構成確認の目標値は次のとおりです。

```text
CONFIG_ATH11K_NSS_SUPPORT=y
CONFIG_NSS_DRV_WIFIOFFLOAD_ENABLE=y
CONFIG_NSS_DRV_WIFI_EXT_VDEV_ENABLE=y
CONFIG_ATH11K_MEM_PROFILE_256M=y
option memory_profile '256mb'
ath11k nss_offload=1 frame_mode=2
```

MX2000のdual-partition sysupgradeは、U-Bootの`boot_part`切替、書き込み後の
read-back、失敗時のNAND書き込み中止を行います。切替に失敗した場合は現在の
partitionへ書き込まず、復旧用の既存イメージを維持します。

実機では、ECMを無効にしたまま、まず2.4 GHzのLAN内通信、次にQCN6122 5 GHz、
最後に両radioを確認します。Wi-Fi NSSはIPQ5018で未検証のため、Apple端末の
4-way handshake失敗、peer再生成、firmware crashに備え、通常seedへ戻せるように
します。検証時は次を使います。

```sh
sh /tmp/verify-ipq5018-nss-boot.sh --wifi
```

### Phase 5以降

IPv6、bridge/VLAN、PPPoE、SQM、Wi-Fi NSSの長時間安定性を個別に追加します。
機能を一度に複数有効化しません。

## 更新運用

```text
origin   https://github.com/haturatu/openwrt-nss-ipq5018.git  (public fork)
qosmio   https://github.com/qosmio/openwrt-ipq.git
upstream https://github.com/openwrt/openwrt.git
```

通常の更新は公式OpenWrtを基底にします。

```sh
git fetch upstream openwrt-25.12
git fetch qosmio 25.12-nss
git rebase upstream/openwrt-25.12
```

NSS差分が競合する場合は、公式側の変更を優先してから、NSS kernel patch、
IPQ5018 DT、MX2000 device profileの順に再検証します。NSS firmware packageは
別feedのrevisionも記録し、driverとのABI不一致を避けます。

## 現時点の判定

MX2000の通常OpenWrt対応とNSS-DP/QCA8337経路、有線NSS core/ECM bring-upは
実機で確認済みです。production autoloadはこのブランチで有効化しましたが、
reboot回数を含む長時間試験は別途必要です。ath11k Wi-Fi NSSは実験機能として
実装済み・未検証であり、完成済みとは扱いません。
