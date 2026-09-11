-- 添加编译规则 debug 和 release
add_rules("mode.debug", "mode.release")

-- 添加第三方库描述目录(mumps库)
add_repositories("ipopt-repo repo", {rootdir = os.scriptdir()})

-- 添加依赖库 mumps
add_requires("mumps")

-- windows的调试库使用D后缀
if is_plat("windows") and is_mode("debug") then
    set_suffixname("D") 
end

-- 添加 ipopt 工程
target("ipopt")
    set_kind("shared")                                          -- 设置为共享库
    add_files("src/**.cpp")                                     -- 添加所有.cpp文件
    add_files("src/**.c")                                       -- 添加所有.c文件 
    add_headerfiles("src/**.h", { prefixdir="coin-or" })        -- 添加所有.h文件
    add_headerfiles("src/**.hpp", { prefixdir="coin-or" })      -- 添加所有.hpp文件
    add_includedirs(os.dirs("src/**"), {public=true})           -- 添加包含目录
    add_defines("IPOPTLIB_BUILD")                               -- 添加编译标识宏
    if is_plat("windows") then
        add_defines("DLL_EXPORT")                               -- 添加动态库导出宏
    end
    add_defines("IPOPT_HAS_MUMPS")                              -- 添加功能标识宏
    add_packages("mumps")                                       -- 添加mumps库
    
    -- 移除不支持的算法的文件
    remove_files("**IpSpralSolverInterface.cpp")
    remove_files("**IpWsmpSolverInterface.cpp")
    remove_files("**IpIterativeWsmpSolverInterface.cpp")
    remove_files("**IpPardisoMKLSolverInterface.cpp")
    remove_files("**IpStdJInterface.cpp")
    remove_files("**AmplSolver**")
target_end()

-- 添加示例目录
includes("examples")
