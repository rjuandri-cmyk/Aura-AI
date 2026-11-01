// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

/**
 * AuraRewards: check-in harian (hadiah tetap) + staking AURA.
 *
 * Staking:
 *  - Fleksibel: bisa tarik kapan saja, hadiah mengalir per detik sesuai flexApyBps.
 *  - Kunci 30 / 90 / 360 hari: hadiah dikunci di muka saat stake (dicadangkan dari pool),
 *    jadi hadiah paket kunci selalu terjamin. Dana + hadiah bisa ditarik setelah masa kunci habis.
 *
 * Pool hadiah = saldo AURA kontrak - total pokok staking - hadiah yang sudah dicadangkan.
 * Pool diisi owner (transfer AURA langsung ke alamat kontrak, atau lewat fund()).
 * Pokok staking pengguna TIDAK pernah dipakai untuk membayar hadiah, dan owner tidak bisa menariknya.
 *
 * Catatan:
 *  - Hadiah fleksibel dibayar dari pool bebas; kalau pool kurang, klaim dibayar sebagian.
 *  - Perubahan flexApyBps berlaku untuk hadiah yang belum diperbarui (hadiah berjalan), bukan paket kunci yang sudah dibuat.
 *  - Token AURA diasumsikan ERC-20 standar tanpa pajak transfer (jumlah masuk dihitung dari selisih saldo).
 */
contract AuraRewards is Ownable, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    uint256 private constant YEAR = 365 days;
    uint256 private constant BPS = 10_000;
    uint32 public constant MAX_APY_BPS = 5_000; // batas atas APY: 50%

    IERC20 public immutable token;

    // ---------- Pengaturan ----------
    struct Plan {
        uint64 duration;
        uint32 apyBps;
        bool enabled;
    }
    Plan[3] public plans; // 0 = 30 hari, 1 = 90 hari, 2 = 360 hari

    uint32 public flexApyBps = 300; // 3% per tahun
    uint256 public checkInReward = 1e18; // 1 AURA per check-in
    uint256 public minBalanceForCheckIn; // 0 = tanpa syarat saldo

    // ---------- Pembukuan ----------
    uint256 public totalStaked; // total pokok (fleksibel + kunci)
    uint256 public reservedLocked; // hadiah paket kunci yang sudah dicadangkan

    struct Flex {
        uint128 amount;
        uint64 lastUpdate;
        uint128 pending;
    }
    mapping(address => Flex) public flex;

    struct LockStake {
        uint128 amount;
        uint128 reward;
        uint64 start;
        uint64 end;
        uint8 plan;
        bool closed;
    }
    mapping(address => LockStake[]) public stakes;

    struct CheckInData {
        uint64 lastDay; // nomor hari UTC + 1 (0 = belum pernah)
        uint32 streak;
        uint32 total;
        uint128 earned; // total hadiah check-in yang sudah diterima
        uint256 history; // bit 0 = hari terakhir check-in, bit i = i hari sebelumnya (256 hari terakhir)
    }
    mapping(address => CheckInData) public checkIns;

    // ---------- Event ----------
    event CheckedIn(address indexed user, uint256 streak, uint256 reward);
    event StakedFlexible(address indexed user, uint256 amount);
    event UnstakedFlexible(address indexed user, uint256 amount);
    event ClaimedFlexible(address indexed user, uint256 amount);
    event StakedLocked(address indexed user, uint256 index, uint8 plan, uint256 amount, uint256 reward, uint64 end);
    event WithdrawnLocked(address indexed user, uint256 index, uint256 amount, uint256 reward);
    event Funded(address indexed from, uint256 amount);
    event ExcessWithdrawn(address indexed to, uint256 amount);

    constructor(address _token) Ownable(msg.sender) {
        require(_token != address(0), "Token tidak valid");
        token = IERC20(_token);
        plans[0] = Plan(30 days, 600, true); // 6% / tahun
        plans[1] = Plan(90 days, 1200, true); // 12% / tahun
        plans[2] = Plan(360 days, 2500, true); // 25% / tahun
    }

    // =====================================================
    //                    VIEW
    // =====================================================

    /// Dana bebas yang bisa dipakai untuk hadiah baru.
    function freeReserve() public view returns (uint256) {
        uint256 bal = token.balanceOf(address(this));
        uint256 used = totalStaked + reservedLocked;
        return bal > used ? bal - used : 0;
    }

    function stakeCount(address user) external view returns (uint256) {
        return stakes[user].length;
    }

    function checkInInfo(address user)
        external
        view
        returns (uint256 lastDay, uint256 streak, uint256 total, bool canCheckIn, uint256 nextAt)
    {
        CheckInData memory c = checkIns[user];
        uint256 today = block.timestamp / 1 days + 1;
        uint256 s = (c.lastDay == today || c.lastDay + 1 == today) ? c.streak : 0;
        return (c.lastDay, s, c.total, c.lastDay != today, today * 1 days);
    }

    /// Data untuk kalender (riwayat 256 hari) dan total hadiah check-in.
    function checkInExtra(address user) external view returns (uint256 history, uint256 earned) {
        CheckInData storage c = checkIns[user];
        return (c.history, c.earned);
    }

    function flexInfo(address user) external view returns (uint256 amount, uint256 pending) {
        Flex memory f = flex[user];
        amount = f.amount;
        pending = f.pending;
        if (f.amount > 0 && block.timestamp > f.lastUpdate) {
            pending += (uint256(f.amount) * flexApyBps * (block.timestamp - f.lastUpdate)) / (YEAR * BPS);
        }
    }

    // =====================================================
    //                   CHECK-IN HARIAN
    // =====================================================

    /// Satu kali per hari (hari dihitung per UTC). Hadiah tetap.
    function checkIn() external nonReentrant whenNotPaused {
        uint64 today = uint64(block.timestamp / 1 days) + 1;
        CheckInData storage c = checkIns[msg.sender];
        require(c.lastDay != today, "Sudah check-in hari ini");
        if (minBalanceForCheckIn > 0) {
            require(token.balanceOf(msg.sender) >= minBalanceForCheckIn, "Saldo AURA belum cukup");
        }

        c.streak = (c.lastDay + 1 == today) ? c.streak + 1 : 1;
        c.history = (c.history << (today - c.lastDay)) | 1; // geser sebanyak hari yang terlewat
        c.lastDay = today;
        c.total += 1;

        uint256 reward = checkInReward;
        if (reward > 0) {
            require(freeReserve() >= reward, "Pool hadiah habis");
            c.earned += uint128(reward);
            token.safeTransfer(msg.sender, reward);
        }
        emit CheckedIn(msg.sender, c.streak, reward);
    }

    // =====================================================
    //                STAKING FLEKSIBEL
    // =====================================================

    function stakeFlexible(uint256 amount) external nonReentrant whenNotPaused {
        require(amount > 0, "Jumlah nol");
        uint256 received = _pull(amount);
        require(received <= type(uint128).max, "Jumlah terlalu besar");
        Flex storage f = flex[msg.sender];
        _accrue(f);
        f.amount += uint128(received);
        totalStaked += received;
        emit StakedFlexible(msg.sender, received);
    }

    /// Tarik pokok fleksibel kapan saja (tetap bisa walau kontrak di-pause).
    function unstakeFlexible(uint256 amount) external nonReentrant {
        Flex storage f = flex[msg.sender];
        require(amount > 0 && f.amount >= amount, "Jumlah tidak valid");
        _accrue(f);
        f.amount -= uint128(amount);
        totalStaked -= amount;
        token.safeTransfer(msg.sender, amount);
        emit UnstakedFlexible(msg.sender, amount);
    }

    function claimFlexible() external nonReentrant {
        Flex storage f = flex[msg.sender];
        _accrue(f);
        uint256 pay = f.pending;
        uint256 free = freeReserve();
        if (pay > free) pay = free;
        require(pay > 0, "Belum ada hadiah yang bisa diklaim");
        f.pending -= uint128(pay);
        token.safeTransfer(msg.sender, pay);
        emit ClaimedFlexible(msg.sender, pay);
    }

    // =====================================================
    //                 STAKING KUNCI 30/90/360
    // =====================================================

    function stakeLocked(uint8 planId, uint256 amount) external nonReentrant whenNotPaused {
        require(planId < 3, "Paket tidak valid");
        Plan memory p = plans[planId];
        require(p.enabled, "Paket sedang nonaktif");
        require(amount > 0, "Jumlah nol");

        uint256 received = _pull(amount);
        require(received <= type(uint128).max, "Jumlah terlalu besar");
        totalStaked += received;

        uint256 reward = (received * p.apyBps * p.duration) / (YEAR * BPS);
        require(freeReserve() >= reward, "Pool hadiah tidak cukup");
        reservedLocked += reward;

        _openLock(planId, received, reward, p.duration);
    }

    function _openLock(uint8 planId, uint256 received, uint256 reward, uint64 duration) internal {
        uint64 end = uint64(block.timestamp) + duration;
        stakes[msg.sender].push(
            LockStake(uint128(received), uint128(reward), uint64(block.timestamp), end, planId, false)
        );
        emit StakedLocked(msg.sender, stakes[msg.sender].length - 1, planId, received, reward, end);
    }

    function withdrawLocked(uint256 index) external nonReentrant {
        LockStake storage s = stakes[msg.sender][index];
        require(!s.closed, "Sudah ditarik");
        require(block.timestamp >= s.end, "Masa kunci belum selesai");
        s.closed = true;
        totalStaked -= s.amount;
        reservedLocked -= s.reward;
        token.safeTransfer(msg.sender, uint256(s.amount) + uint256(s.reward));
        emit WithdrawnLocked(msg.sender, index, s.amount, s.reward);
    }

    // =====================================================
    //                      OWNER
    // =====================================================

    /// Isi pool hadiah (perlu approve dulu). Transfer langsung ke kontrak juga dihitung.
    function fund(uint256 amount) external {
        token.safeTransferFrom(msg.sender, address(this), amount);
        emit Funded(msg.sender, amount);
    }

    /// Ambil kembali dana bebas. Tidak bisa menyentuh pokok staking maupun hadiah yang sudah dicadangkan.
    function withdrawExcess(uint256 amount) external onlyOwner nonReentrant {
        require(amount <= freeReserve(), "Melebihi dana bebas");
        token.safeTransfer(msg.sender, amount);
        emit ExcessWithdrawn(msg.sender, amount);
    }

    /// Hanya berlaku untuk stake kunci BARU.
    function setPlan(uint8 id, uint32 apyBps, bool enabled) external onlyOwner {
        require(id < 3, "Paket tidak valid");
        require(apyBps <= MAX_APY_BPS, "APY terlalu tinggi");
        plans[id].apyBps = apyBps;
        plans[id].enabled = enabled;
    }

    function setFlexApy(uint32 apyBps) external onlyOwner {
        require(apyBps <= MAX_APY_BPS, "APY terlalu tinggi");
        flexApyBps = apyBps;
    }

    function setCheckInReward(uint256 reward) external onlyOwner {
        checkInReward = reward;
    }

    /// Syarat saldo minimum di dompet untuk check-in (anti banyak akun). 0 = nonaktif.
    function setMinBalanceForCheckIn(uint256 minBalance) external onlyOwner {
        minBalanceForCheckIn = minBalance;
    }

    /// Menghentikan check-in dan stake BARU. Penarikan pokok tetap berjalan.
    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    // =====================================================
    //                     INTERNAL
    // =====================================================

    function _pull(uint256 amount) internal returns (uint256 received) {
        uint256 beforeBal = token.balanceOf(address(this));
        token.safeTransferFrom(msg.sender, address(this), amount);
        received = token.balanceOf(address(this)) - beforeBal;
        require(received > 0, "Tidak ada token masuk");
    }

    function _accrue(Flex storage f) internal {
        if (f.amount > 0 && block.timestamp > f.lastUpdate) {
            f.pending += uint128(
                (uint256(f.amount) * flexApyBps * (block.timestamp - f.lastUpdate)) / (YEAR * BPS)
            );
        }
        f.lastUpdate = uint64(block.timestamp);
    }
}
