add_rules("mode.debug", "mode.release")
add_requires("mumps")

add_repositories("ipopt-repo repo", {rootdir = os.scriptdir()})

target("ipopt")
    set_kind("shared")
    add_files("src/**.cpp")
    add_files("src/**.c")
    add_headerfiles("src/**.h", { prefixdir="coin-or" })
    add_headerfiles("src/**.hpp", { prefixdir="coin-or" })
    add_includedirs(os.dirs("src/**"), {public=true})
    add_defines("IPOPTLIB_BUILD")
    add_defines("DLL_EXPORT")
    add_defines("IPOPT_HAS_MUMPS")
    add_packages("mumps")
    
    remove_files("**IpSpralSolverInterface.cpp")
    remove_files("**IpWsmpSolverInterface.cpp")
    remove_files("**IpIterativeWsmpSolverInterface.cpp")
    remove_files("**IpPardisoMKLSolverInterface.cpp")
    remove_files("**IpStdJInterface.cpp")
    remove_files("**AmplSolver**")


includes("examples")
