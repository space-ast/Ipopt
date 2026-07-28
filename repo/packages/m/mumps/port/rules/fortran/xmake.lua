--! Fortran module dependency scanner rule for MUMPS
--!
--! This rule scans Fortran source files for MODULE/USE dependencies,
--! builds a dependency DAG, and reorders source files so that
--! module providers are compiled before module consumers.
--!
--! Usage:
--!   target("foo")
--!       set_languages("fortran")
--!       add_rules("fortran.build.modules.scanner")   -- add this line
--!       add_files("src/*.F")
--!
--! This rule does NOT modify xmake's built-in code.
--! It works by intercepting the prepare phase and reordering
--! fortran.build's sourcebatch arrays in-place before compilation begins.
--!
--! @file        xmake.lua
--!

-- ============================================================================
--  Rule: fortran.build.modules.scanner
-- ============================================================================
rule("fortran.build.modules.scanner")

    -- Create a lightweight sourcebatch (sourcefiles only, no objectfiles)
    -- to avoid duplicate compilation with fortran.build
    set_sourcekinds("fc", {objectfiles = false})

    -- Intercept the prepare phase to scan and reorder source files
    -- BEFORE fortran.build's on_build_files runs
    on_prepare_files(function (target, jobgraph, sourcebatch, opt)

        -- Get fortran.build's sourcebatch (the one that actually compiles files)
        local sourcebatches = target:sourcebatches()
        local fb_batch = sourcebatches["fortran.build"]
        if not fb_batch or not fb_batch.sourcefiles or #fb_batch.sourcefiles == 0 then
            return
        end

        -- Import the scanner
        local scanner = import("scanner", {rootdir = os.scriptdir()})

        -- Scan, build DAG, and topologically sort
        local sorted, providers, edge_count = scanner.scan_and_sort(
            target,
            fb_batch.sourcefiles,
            target:name()
        )

        -- If no module dependencies found, nothing to reorder
        if edge_count == 0 then
            return
        end

        -- Build lookup maps from original order
        local obj_map = {}
        local dep_map = {}
        for i, sf in ipairs(fb_batch.sourcefiles) do
            obj_map[sf] = fb_batch.objectfiles[i]
            dep_map[sf] = fb_batch.dependfiles[i]
        end

        -- Reorder fortran.build's sourcebatch arrays in-place
        -- (these arrays are references into target._SOURCEBATCHES cache,
        --  so fortran.build will see the reordered arrays when it runs)
        local new_objectfiles = {}
        local new_dependfiles = {}
        for _, sf in ipairs(sorted) do
            table.insert(new_objectfiles, obj_map[sf])
            table.insert(new_dependfiles, dep_map[sf])
        end

        fb_batch.sourcefiles = sorted
        fb_batch.objectfiles = new_objectfiles
        fb_batch.dependfiles = new_dependfiles
    end)
