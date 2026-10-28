# vasp-scripts

VASP 计算辅助脚本（Gadi PBS 和 Setonix Slurm 都能用）。
提交作业的脚本会按 runscript 头部（`#PBS` 或 `#SBATCH`）或系统里有哪个命令（`qsub` / `sbatch`）自动选择调度器。
脚本之间互相调用时，先找本脚本所在目录，再找 `PATH`，最后才用旧的绝对路径。

**共享库**（仓库根目录需在 `PATH` 中；脚本被复制到计算目录后也靠 `PATH` 找到它们）：

| 文件 | 内容 |
|---|---|
| `vasp_common.sh` | bash 函数（被其他脚本 `source`）：INCAR 读写 `incar_get/incar_set/incar_comment`（不区分大小写、保留注释、处理 `;` 行、不留重复标签）；POSCAR `poscar_species`（去掉 `_pv`、`/hash`）、`lmaxmix_for_poscar`、`poscar_vacuum_c`、`kpath_task`（2D→302，体相→303）；作业 `find_runscript`（只读文件前 4 KB，多个时询问，`RUNSCRIPT=` 可指定）、`sched_of`、`submit_job`、`job_active`（调度器出错时重试 3 次）、`vasp_job_status`（收敛判据与 `VASP_JOB_PARAMETERS` 相同）；`find_tool`、`die/warn/confirm`。文件头有完整说明 |
| `vasp_common.py` | Python 函数：`read_poscar`（VASP4/5/6、`Ti_pv/hash`、Selective dynamics、负缩放因子、Cartesian）、`write_poscar`、`group_order`、`neighbor_pairs`/`mic_dists`（27 个镜像，向量化）、`periodic_com`、`read_incar`、`outcar_tail`/`outcar_contains`（不把整个 OUTCAR 读进内存）、`oszicar_last`、`job_status`、`read_atoms`（旧版 ASE 读不了 VASP 6.4 物种名时自动改用 `read_poscar`） |

收敛判据（`VASP_JOB_PARAMETERS`、workflow、`vasp_nupdown_test.sh`、`superfrac_slurm.sh`、`scan_vasp_energies.py` 共用）：
NSW 缺省或 ≤ 0 → 静态，看 `EDIFF is reached`；IBRION = 1/2/3/44 → 还需 `reached required accuracy`；其余（MD、频率等）→ `EDIFF is reached`。

> Wannier90 / WannierTools 相关脚本（`wannier_*.py`、`wt-input-generator.sh` 等）已移到 `wannier90-script` 仓库，文件名不变。`qe2poscar.py` 在 `qe-script` 里。

## 作业模板与作业结束钩子

| 文件 | 用途 |
|---|---|
| `vasp_runscript_setonix` | Setonix Slurm 作业模板（VASP 6.4.3） |
| `VASP_JOB_PARAMETERS` | 作业结束钩子的实现：备份并重命名输出、判断是否收敛、写 `~/vasp_job_log`（失败另写 `~/vasp_fail_log`，作业返回 1）、Bader、静态计算的带隙和 DOS；路径由 `find_tool` 查找（旧绝对路径优先） |
| `VASP_JOB_PARAMETERS_slurm` / `VASP_JOB_PARAMETERS_gadi` | runscript 里 `source` 的仍是这两个文件名：各 3 行，设置站点（`VJP_SITE`）后加载 `VASP_JOB_PARAMETERS`（同目录，否则 `PATH`）。Gadi：总是备份、`band_vaspkit.py`、`VASP_AUTO_SUBMISSION`、`CHECK_AUTO_STOP`；Slurm：IBRION=-1 时不备份 |
| `vasp_incar` | 带注释的 INCAR 总模板（band/dos/soc/stm 脚本会取消其中 `# KEY` 行的注释） |
| `vasp_clean.sh` | 递归删除大文件（WAVECAR/CHGCAR/`*_hr.dat` 等）；先列出数量和大小再确认，`-n` 只列出，`-y` 不确认 |
| `jobtrack/` | 作业提交记录与 fzf 浏览工具（PBS/Slurm/本地），见 `jobtrack/README.md` |

## 自动化工作流

| 脚本 | 用途 |
|---|---|
| `vasp_workflow_input_generator.sh` | 生成 step0–5（gamma 预优化 → 优化 → 优化 → SCF → 能带 → DOS）的 INCAR、KPOINTS、作业脚本和串行 workflow 脚本 `<prefix>.sh`（PBS 或 Slurm）。参数：`--scheduler auto\|pbs\|slurm --prefix --steps "0 1 2" --run --offset --dipole y\|n --scf-dir --runscript --yes`（`--help`），缺的才会问。workflow 被杀掉后重新 `nohup ./<prefix>.sh &` 即可：已完成的步骤（`.workflow_stepN.done` 或 SCF/BAND/DOS 目录已收敛）跳过，正在排队/运行的作业接着等，不会重复提交；`FORCE_RERUN=1` 全部重跑 |
| `vasp_workflow_input_generator_setonix.sh` / `_gadi.sh` | 旧名字，仍可用（含管道输入的回答）：= `--scheduler slurm` / `--scheduler pbs`，提问方式、作业编号和 SCF 目录名与原脚本相同 |
| `vasp_para_conv.sh` | 通用 INCAR 参数扫描：生成目录并提交（`-h` 查看帮助） |
| `vasp_nupdown_test.sh` | 缺陷 NUPDOWN 测试：提交后汇总，找出能量最低的态（`-m test\|summary -d "v_S*" -s 脚本 -y/-n`，不给就用菜单） |
| `scan_vasp_energies.py` | 按每原子能量给子目录排序 → `vasp_energy_scan.log`（静态计算也算完成） |
| `grad.py` | OUTCAR 弛豫监控（能量、SCF 次数、受力） |
| `sigma.sh` | 检查 T·S/原子 < 1 meV |

## 后续计算的搭建（在已收敛的目录里运行）

| 脚本 | 用途 |
|---|---|
| `non_sc_calculation.sh` | 由弛豫结果搭一个 SCF 静态计算目录（`NON-SC-kmesh-0.03/`），自动选 vasp_gam/std |
| `band_structure_calculation.sh` | 能带（ICHARG=11；c 方向真空 > 8 Å 用 vaspkit 302，否则 303；`--2d/--3d` 指定） |
| `dos_calculation.sh` | DOS（`-e EMIN EMAX`） |
| `soc_calculation.sh` | SOC（vasp_ncl、NBANDS×2） |
| `stm-calculations.sh` / `plot-stm.sh` | STM 部分电荷：搭建（`-y/-n` 直接决定是否提交）/ vaspkit 作图 |
| `gibbs.sh` → `get_idm.py` | 频率计算（IBRION=5）→ 由频率结果生成 IDM 输入（IBRION=44） |
| `chgcent.py` | 电荷中心与偶极（CHGCAR + OUTCAR） |
| `center-of-mass.py` | POSCAR 质心（分数坐标），workflow/gibbs 用它设置 DIPOL |
| `fatband_analysis.py` | pyprocar 按元素、壳层批量画 fatband（用于选 Wannier 投影） |

## 结构生成与检查

| 脚本 | 用途 |
|---|---|
| `vasp_strain_gen.sh` | 正应变系列（正交 / 六方晶胞），可以自动接上 workflow（Setonix，用参数调用生成器） |
| `vasp_strain.sh` + `deform_strain.sh` + `vasp_strain_analysis.sh` | 任意应变分量（含剪切）→ 提交 → EFG 汇总 |
| `make_mag_supercell.py` | 带 MAGMOM 的超胞 |
| `gen_amorphous.py` | 非晶 AIMD 初始结构（随机空位 + 扰动） |
| `vacancy_generator.py` | 用 spglib 枚举不等价的空位 / 替位组合 |
| `superfrac_slurm.sh` + `supercell` | 无序结构枚举 → 计算 → 能量汇总（PBS/Slurm；`-p 前缀 -i CIF -s 2x2x2 generate convert submit extract`，不给动作就用菜单） |
| `crystal_rotator.sh` | atomkit 旋转结构 |
| `atomic_distance_checker.py` | 检查原子间距是否过近（PBC，支持 Selective dynamics） |
| `xyz2pos.py` | xyz → POSCAR |

## 缺陷

| 脚本 | 用途 |
|---|---|
| `doped_workflow.sh` | ShakeNBreak 各步骤的命令提示（`REMOTE_MACHINE`/`REMOTE_PATH` 可用环境变量覆盖） |
| `doped_extract_poscars.sh` | 收集 doped 结构 |
| `sxdefectalign2d_workflow.sh` + `sxdefectalign2d_iterative.py` + `sxdefectalign2d_system.sx` | 2D 带电缺陷修正（参考 LOCPOT 用 `--vref` 或 `VREF_LOCPOT` 指定） |

## 二进制

| 文件 | 来源 |
|---|---|
| `bader` | Henkelman Bader v1.05（静态链接） |
| `supercell` | Okhotnikov supercell |
| `vasp-xdat-analyzer` | 由 `vasp-xdat-analyzer.f90` 编译：`gfortran -O2 -o vasp-xdat-analyzer vasp-xdat-analyzer.f90` |

## 外部依赖

vaspkit / atomkit、VTST `chgsum.pl`、python3（numpy/ASE/spglib/pyprocar）、sxdefectalign2d、ShakeNBreak。
