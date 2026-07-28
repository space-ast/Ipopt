--! Fortran module dependency scanner for MUMPS
--!
--! Scans Fortran source files to extract MODULE definitions and USE statements,
--! builds a dependency DAG, and topologically sorts source files so that
--! module providers are compiled before module consumers.
--!
--! This is a project-local rule — it does NOT modify xmake's built-in code.
--!
--! @file        scanner.lua
--!

-- imports
import("core.base.graph")
import("core.base.hashset")

-- ============================================================================
--  Read Fortran source and extract logical statements
--
--  MUMPS uses Fortran fixed format (.F files):
--    Column 1:    C/c/*/!/D/d/# → comment line
--    Columns 1-5: label (optional)
--    Column 6:    continuation mark (non-blank → this line continues previous)
--    Columns 7-72: statement
--
--  For MODULE and USE scanning, we can safely:
--    1. Skip comment lines and blank lines
--    2. Skip continuation lines (they never START a MODULE/USE)
--    3. Extract columns 7+ as the statement
-- ============================================================================
local function read_fortran_statements(sourcefile)
    local raw = io.readfile(sourcefile)
    if not raw then
        return {}
    end

    local stmts = {}
    for raw_line in raw:gmatch("[^\r\n]+") do
        -- Remove trailing carriage return (Windows CRLF)
        raw_line = raw_line:gsub("\r$", "")

        -- Expand tabs to spaces for consistent column counting
        -- (tab is rare in MUMPS, but be safe)
        raw_line = raw_line:gsub("\t", "        ")

        -- Skip blank lines
        if raw_line:match("^%s*$") then
            goto next_line
        end

        -- Skip comment lines: C, c, *, !, D, d, # in column 1
        local first = raw_line:sub(1, 1)
        if first == "C" or first == "c" or first == "*"
           or first == "!" or first == "D" or first == "d"
           or first == "#" then
            goto next_line
        end

        -- Skip continuation lines: column 6 non-blank
        -- These lines extend the previous line's statement,
        -- never start a new MODULE or USE
        if #raw_line >= 6 then
            local col6 = raw_line:sub(6, 6)
            if col6 ~= " " then
                goto next_line
            end
        end

        -- Extract statement from column 7 onward
        local stmt
        if #raw_line >= 7 then
            stmt = raw_line:sub(7)
        else
            stmt = raw_line
        end
        stmt = stmt:trim()
        if stmt ~= "" then
            table.insert(stmts, stmt)
        end

        ::next_line::
    end
    return stmts
end

-- ============================================================================
--  Scan a single Fortran source file for MODULE definitions and USE statements
--  Returns:
--    provides: set of module names (lowercased) that this file defines
--    requires: set of module names (lowercased) that this file uses
-- ============================================================================
function scan_source(sourcefile)
    local provides = {}
    local requires = {}

    local stmts = read_fortran_statements(sourcefile)

    for _, stmt in ipairs(stmts) do
        -- Remove inline comments: everything after ! (not inside strings)
        stmt = stmt:gsub("%s*!.*$", ""):trim()
        if stmt == "" then
            goto continue
        end

        local upper = stmt:upper()

        -- ================================================================
        -- MODULE xxx
        -- Exclude: END MODULE, MODULE PROCEDURE, MODULE SUBROUTINE,
        --          MODULE FUNCTION, SUBMODULE
        -- ================================================================
        local mod_match = upper:match("^MODULE%s+([%w_]+)")
        if mod_match then
            if not upper:match("^%s*END%s+MODULE")
               and not upper:match("^MODULE%s+PROCEDURE")
               and not upper:match("^MODULE%s+SUBROUTINE")
               and not upper:match("^MODULE%s+FUNCTION") then
                provides[mod_match:lower()] = true
            end
            goto continue
        end

        -- SUBMODULE (Fortran 2008) — skip for now
        if upper:match("^SUBMODULE") then
            goto continue
        end

        -- ================================================================
        -- USE xxx
        -- Handles: USE mod, USE mod, ONLY: ..., USE :: mod
        -- ================================================================
        local use_match = upper:match("^USE%s+[:%s]*([%w_]+)")
        if use_match then
            local modname = use_match:lower()
            -- Skip Fortran intrinsic modules
            if modname ~= "intrinsic"
               and modname ~= "iso_fortran_env"
               and modname ~= "iso_c_binding"
               and modname ~= "ieee_arithmetic"
               and modname ~= "ieee_exceptions"
               and modname ~= "ieee_features"
               and modname ~= "omp_lib" then
                requires[modname] = true
            end
            goto continue
        end

        ::continue::
    end

    return provides, requires
end

-- ============================================================================
--  Build module dependency DAG and topologically sort source files
-- ============================================================================
function build_dag(sourcefiles, target_name)
    target_name = target_name or ""

    -- Build module provider map: module_name → sourcefile
    local providers = {}
    for _, sf in ipairs(sourcefiles) do
        local provides = scan_source(sf)
        for mod in pairs(provides) do
            if providers[mod] and providers[mod] ~= sf then
                raise("duplicate module '%s' defined in:\n  %s\n  %s",
                      mod:upper(), providers[mod], sf)
            end
            providers[mod] = sf
        end
    end

    -- Build DAG: if B uses module M and A defines M, add edge A → B
    local dag = graph.new(true)
    for _, sf in ipairs(sourcefiles) do
        local _, requires = scan_source(sf)
        for mod in pairs(requires) do
            local provider = providers[mod]
            if provider and provider ~= sf then
                dag:add_edge(provider, sf)
            end
        end
    end

    -- Topological sort
    local sorted, has_cycle = dag:topo_sort()
    if has_cycle then
        local cycle = dag:find_cycle()
        if cycle then
            local names = {}
            for _, sf in ipairs(cycle) do
                local mods = {}
                for mod, prov in pairs(providers) do
                    if prov == sf then
                        table.insert(mods, mod:upper())
                    end
                end
                table.insert(names, sf .. " [" .. table.concat(mods, ", ") .. "]")
            end
            raise("[%s] circular module dependency detected:\n  %s",
                  target_name, table.concat(names, "\n  -> "))
        else
            raise("[%s] circular module dependency detected", target_name)
        end
    end

    -- Include files with no module dependencies
    local sorted_set = hashset.from(sorted)
    for _, sf in ipairs(sourcefiles) do
        if not sorted_set:has(sf) then
            table.insert(sorted, sf)
            sorted_set:insert(sf)
        end
    end

    return sorted, providers, #dag:edges()
end

-- ============================================================================
--  Main entry point: scan and sort for a target
-- ============================================================================
function scan_and_sort(target, sourcefiles, target_name)
    if not sourcefiles or #sourcefiles == 0 then
        return {}, {}, 0
    end

    local sorted, providers, edge_count = build_dag(sourcefiles, target_name)

    if edge_count > 0 then
        -- Count how many files have dependencies (need ordering)
        local dep_count = 0
        for _, sf in ipairs(sourcefiles) do
            local _, requires = scan_source(sf)
            for mod in pairs(requires) do
                if providers[mod] and providers[mod] ~= sf then
                    dep_count = dep_count + 1
                    break
                end
            end
        end
        print(string.format("[fortran.scanner] %s: %d files, %d module edges, %d files with deps",
              target_name, #sourcefiles, edge_count, dep_count))
    else
        print(string.format("[fortran.scanner] %s: %d files, no module dependencies",
              target_name, #sourcefiles))
    end

    return sorted, providers, edge_count
end
