-- ===========================================================================
--  MUMPS 5.7.3 — xmake 构建配置
--  工具链: gfortran + MinGW-w64
--  产物:   libdmumps.dll / libsmumps.dll / libcmumps.dll / libzmumps.dll
--  使用:   xmake f -m release ; xmake
-- ===========================================================================

-- 本地 Fortran 模块依赖扫描规则
includes("rules/fortran/xmake.lua")

-- 全局配置
add_rules("mode.debug", "mode.release")

-- 强制使用 MinGW 工具链 (MSVC 的 C 对象与 gfortran 的 Fortran 对象互不兼容)


add_includedirs("include")
add_fcflags("-fallow-argument-mismatch")
-- C 符号约定: gfortran 末尾加一个下划线
add_defines("Add_", "pord")

-- ===========================================================================
-- 依赖包: OpenBLAS (自带 LAPACK 接口)
-- ===========================================================================
add_requires("openblas")
add_requires("mingw-w64")

-- ===========================================================================
-- 选项: 精度选择
-- ===========================================================================
option("arithmetics")
    set_default("d")
    set_showmenu(true)
    set_description("MUMPS arithmetic precisions to build: d, s, c, z, or all")
    set_values("d", "s", "c", "z", "all")

-- ===========================================================================
-- PORD — 排序库 (纯 C)
-- ===========================================================================
target("pord")
    set_toolchains("mingw")
    set_kind("static")
    add_files("PORD/lib/*.c")
    add_includedirs("PORD/include", {public=true})

-- ===========================================================================
-- mpiseq — MPI 桩库 (Fortran + C), 替代真正的 MPI
-- ===========================================================================
target("mpiseq")
    set_toolchains("mingw")
    set_kind("static")
    add_files("libseq/*.f")
    add_files("libseq/*.c")
    add_headerfiles("libseq/*.h")
    add_includedirs("libseq", {public=true})

-- ===========================================================================
-- mumps_common — 算术无关的公共代码
-- ===========================================================================
target("mumps_common")
    set_kind("static")
    add_rules("fortran.build.modules.scanner")

    set_toolchains("mingw")
    -- 自动生成 include/mumps_int_def.h (32-bit 默认)
    -- 如需 64-bit 整数, 删除此文件后重新生成, 并定义 DINTSIZE64
    before_build(function (target)
        local header = path.join(os.projectdir(), "include", "mumps_int_def.h")
        if not os.isfile(header) then
            local src = path.join(os.projectdir(), "src", "mumps_int_def32_h.in")
            print("[mumps] generating include/mumps_int_def.h (32-bit integers)")
            os.cp(src, header)
        end
    end)
    -- 公共 Fortran 源 (不以 s/c/d/z 开头)
    add_files("src/ana_*.F")
    add_files("src/bcast_*.F")
    add_files("src/estim_*.F")
    add_files("src/double_*.F")
    add_files("src/fac_*.F")
    add_files("src/front_*.F")
    add_files("src/lr_*.F")
    add_files("src/mumps_*.F")
    add_files("src/omp_*.F")
    add_files("src/sol_*.F")
    add_files("src/tools_*.F")
    -- 公共 C 源 (排除 mumps_c.c, 它按算术分别编译)
    add_files("src/mumps_*.c|mumps_c.c")
    add_defines("pord")
    add_packages("openblas")
    add_deps("pord", "mpiseq")

-- ===========================================================================
-- 辅助函数: 为指定算术创建共享库 target
-- ===========================================================================
local function add_mumps_shared_target(arith)
    local arith_name = arith .. "mumps"
    -- target(arith_name .. "_fc")
    --     set_kind("object")
    --     add_rules("fortran.build.modules.scanner")
    --     -- 算术相关 Fortran 源 (例如 d*.F)
    --     add_files("src/" .. arith .. "*.F")
    --     add_deps("mumps_common", "pord", "mpiseq")

    target(arith_name)
        set_kind("shared")
        set_toolchains("mingw")
        add_defines("MUMPS_CALL=__declspec(dllexport)")
        
        -- 算术相关 C 源 (例如 dmumps_gpu.c)
        add_files("src/" .. arith .. "*.c")

        -- mumps_c.c: 每次编译定义不同算术宏 (MUMPS_ARITH_s/d/c/z)
        add_files("src/mumps_c.c", {defines = "MUMPS_ARITH=MUMPS_ARITH_" .. arith})
        
        after_link(function(target)
            import("utils.platform.gnu2mslib")
            gnu2mslib(target:artifactfile("implib"), "dmumps.def", {arch="x64"})
        end)

        on_config(function(target)
            local mingw = import("detect.sdks.find_mingw")()
            local bindir = mingw.bindir
            if mingw and bindir then
                target:add("installfiles", path.join(bindir, "libgcc_s_seh-1.dll"), {prefixdir="bin"})
                target:add("installfiles", path.join(bindir, "libwinpthread-1.dll"), {prefixdir="bin"})
                target:add("installfiles", path.join(bindir, "libgfortran-5.dll"), {prefixdir="bin"})
                target:add("installfiles", path.join(bindir, "libquadmath-0.dll"), {prefixdir="bin"})
            end
        end)

        -- 依赖
        add_deps("mumps_common", "pord", "mpiseq")
        add_packages("openblas")

        if false then
            add_deps(arith_name .. "_fc")
            -- gfortran 运行时库的 MSVC 导入库 (用 gendef + dlltool 从 DLL 生成)
            add_linkdirs("D:/Programs/mingw64/bin")
            add_links("libgfortran-5", "libgcc_s_seh-1", "libquadmath-0", "libwinpthread-1")
            -- ___chkstk_ms 在 libgcc.a 里, DLL 不导出, 需单独链接
            add_linkdirs("build/gfortran_stubs")
            add_links("libgcc_chkstk")
        else
            add_rules("fortran.build.modules.scanner")
            add_files("src/" .. arith .. "*.F")
            add_syslinks("pthread")
        end
end

-- ===========================================================================
-- 根据选项生成算术 target
-- ===========================================================================
local arith_opt = get_config("arithmetics") or "d"

if arith_opt == "all" then
    for _, a in ipairs({"s", "d", "c", "z"}) do
        add_mumps_shared_target(a)
    end
else
    add_mumps_shared_target(arith_opt)
end

-- ===========================================================================
-- 安装配置
-- ===========================================================================
target("mumps_headers")
    set_kind("headeronly")
    add_headerfiles("include/(*.h)")
    add_headerfiles("include/(mumps_compat.h)")
    add_headerfiles("include/(mumps_c_types.h)")

-- ===========================================================================
-- 示例程序 (可选, xmake build --all 时构建)
-- ===========================================================================
target("dsimpletest")
    set_kind("binary")
    set_default(false)  -- 默认不构建
    set_toolchains("mingw")
    add_files("examples/dsimpletest.F")
    add_deps("dmumps")
    add_packages("openblas")

target("c_example")
    set_kind("binary")
    set_default(false)
    set_toolchains("mingw")
    add_files("examples/c_example.c")
    add_deps("dmumps")
    add_packages("openblas")
