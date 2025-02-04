--[[
 Simple Command Line Option Parsing for Lua 5.1, 5.2, 5.3 & 5.4
 Copyright (C) 2014-2018, 2021-2022 Gary V. Vaughan
]]
--[[--
 Parse and process command line options.

 In the common case, you can write the long-form help output typical of
 a modern-command line program, and let this module generate a custom
 parser that collects and diagnoses the options it describes.

 The parser is an object instance which can then be tweaked for
 the uncommon case, by hand, or by using the @{on} method to tie your
 custom handlers to options that are not handled quite the way you'd
 like.

 @module optparse
]]


local _ENV = require 'optparse._strict' {
   assert = assert,
   error = error,
   exit = os.exit,
   find = string.find,
   getmetatable = getmetatable,
   gsub = string.gsub,
   insert = table.insert,
   ipairs = ipairs,
   lower = string.lower,
   match = string.match,
   next = next,
   nonempty = next,
   open = io.open,
   pcall = pcall,
   print = print,
   rawset = rawset,
   require = require,
   setmetatable = setmetatable,
   stderr = io.stderr,
   sub = string.sub,
   tostring = tostring,
   type = type,
}



--[[ ================= ]]--
--[[ Helper Functions. ]]--
--[[ ================= ]]--


local function iscallable(x)
   return type((getmetatable(x) or {}).__call or x) == 'function'
end


local function getmetamethod(x, n)
   local m = (getmetatable(x) or {})[tostring(n)]
   if iscallable(m) then
      return m
   end
end


local function rawlen(x)
   if type(x) ~= 'table' then
      return #x
   end

   local n = #x
   for i = 1, n do
      if x[i] == nil then
         return i - 1
      end
   end
   return n
end


local function len(x)
   local m = getmetamethod(x, '__len')
   if m then
      return m(x)
   end
   if getmetamethod(x, '__tostring') then
      x = tostring(x)
   end
   return rawlen(x)
end


local function merge(t, r)
   r = r or {}
   for k, v in next, t do
      r[k] = r[k] or v
   end
   return r
end


local function extend(r, items)
   for i = 1, len(items) do
      r[#r + 1] = items[i]
   end
end


local function last(t)
   return t[len(t)]
end


local optional, required


--- Expand an argument list.
-- Separate short options, remove `=` separators from
-- `--long-option=optarg` etc.
-- @local
-- @function expandargs
-- @tparam table arglist list of arguments to expand
-- @treturn table expanded argument list
local function expandargs(self, arglist)
   local r = {}
   local i = 0
   while i < len(arglist) do
      i = i + 1
      local opt = arglist[i]

      -- Split '--long-option=option-argument'.
      if match(opt, '^%-%-') then
         local x = find(opt, '=', 3, true)
         if x then
            local optname = sub(opt, 1, x -1)

            -- Only split recognised long options.
            if self[optname] then
               extend(r, {optname, sub(opt, x + 1)})
            else
               x = nil
            end
         end

         if x == nil then
            -- No '=', or substring before '=' is not a known option name.
            insert(r, opt)
         end

      elseif sub(opt, 1, 1) == '-' and len(opt) > 2 then
         local orig, split, rest = opt, {}
         repeat
            opt, rest = match(opt, '^(%-%S)(.*)$')
            insert(split, opt)

            -- If there's no handler, the option was a typo, or not supposed
            -- to be an option at all.
            if self[opt] == nil then
               opt, split = nil, {orig}

            -- Split '-xyz' into '-x -yz', and reiterate for '-yz'
            elseif self[opt].handler ~= optional and
               self[opt].handler ~= required then
               if len(rest) > 0 then
                  opt = '-' .. rest
               else
                  opt = nil
               end

            -- Split '-xshortargument' into '-x shortargument'.
            else
               insert(split, rest)
               opt = nil
            end
         until opt == nil

         -- Append split options to expanded list
         extend(r, split)
      else
         insert(r, opt)
      end
   end

   r[-1], r[0] = arglist[-1], arglist[0]
   return r
end


--- Store `value` with `opt`.
-- @local
-- @function set
-- @string opt option name
-- @param value option argument value
local function set(self, opt, value)
   local key = self[opt].key
   local opts = self.opts[key]

   if type(opts) == 'table' then
      insert(opts, value)
   elseif opts ~= nil then
      self.opts[key] = {opts, value}
   else
      self.opts[key] = value
   end
end



--[[ ============= ]]--
--[[ Option Types. ]]--
--[[ ============= ]]--


--- Option at `arglist[i]` can take an argument.
-- Argument is accepted only if there is a following entry that does not
-- begin with a '-'.
--
-- This is the handler automatically assigned to options that have
-- `--opt=[ARG]` style specifications in the @{OptionParser} spec
-- argument.   You can also pass it as the `handler` argument to @{on} for
-- options you want to add manually without putting them in the
-- @{OptionParser} spec.
--
-- Like @{required}, this handler will store multiple occurrences of a
-- command-line option.
-- @static
-- @tparam table arglist list of arguments
-- @int i index of last processed element of *arglist*
-- @param[opt=true] value either a function to process the option
--    argument, or a default value if encountered without an optarg
-- @treturn int index of next element of *arglist* to process
-- @usage
-- parser:on('--enable-nls', parser.optional, parser.boolean)
function optional(self, arglist, i, value)
   if i + 1 <= len(arglist) and sub(arglist[i + 1], 1, 1) ~= '-' then
      return self:required(arglist, i, value)
   end

   if iscallable(value) then
      value = value(self, arglist[i], nil)
   elseif value == nil then
      value = true
   end

   set(self, arglist[i], value)
   return i + 1
end


--- Option at `arglist[i]` requires an argument.
--
-- This is the handler automatically assigned to options that have
-- `--opt=ARG` style specifications in the @{OptionParser} spec argument.
-- You can also pass it as the `handler` argument to @{on} for options
-- you want to add manually without putting them in the @{OptionParser}
-- spec.
--
-- Normally the value stored in the `opt` table by this handler will be
-- the string given as the argument to that option on the command line.
-- However, if the option is given on the command-line multiple times,
-- `opt['name']` will end up with all those arguments stored in the
-- array part of a table:
--
--       $ cat ./prog
--       ...
--       parser:on({'-e', '-exec'}, required)
--       _G.arg, _G.opt = parser:parse(_G.arg)
--       print(tostring(_G.opt.exec))
--       ...
--       $ ./prog -e '(foo bar)' -e '(foo baz)' -- qux
--       {1=(foo bar),2=(foo baz)}
-- @static
-- @tparam table arglist list of arguments
-- @int i index of last processed element of *arglist*
-- @param[opt] value either a function to process the option argument,
--    or a forced value to replace the user's option argument.
-- @treturn int index of next element of *arglist* to process
-- @usage
-- parser:on({'-o', '--output'}, parser.required)
function required(self, arglist, i, value)
   local opt = arglist[i]
   if i + 1 > len(arglist) then
      self:opterr("option '" .. opt .. "' requires an argument")
      return i + 1
   end

   if iscallable(value) then
      value = value(self, opt, arglist[i + 1])
   elseif value == nil then
      value = arglist[i + 1]
   end

   set(self, opt, value)
   return i + 2
end


--- Finish option processing
--
-- This is the handler automatically assigned to the option written as
-- `--` in the @{OptionParser} spec argument.   You can also pass it as
-- the `handler` argument to @{on} if you want to manually add an end
-- of options marker without writing it in the @{OptionParser} spec.
--
-- This handler tells the parser to stop processing arguments, so that
-- anything after it will be an argument even if it otherwise looks
-- like an option.
-- @static
-- @tparam table arglist list of arguments
-- @int i index of last processed element of `arglist`
-- @treturn int index of next element of `arglist` to process
-- @usage
-- parser:on('--', parser.finished)
local function finished(self, arglist, i)
   for opt = i + 1, len(arglist) do
      insert(self.unrecognised, arglist[opt])
   end
   return 1 + len(arglist)
end


--- Option at `arglist[i]` is a boolean switch.
--
-- This is the handler automatically assigned to options that have
-- `--long-opt` or `-x` style specifications in the @{OptionParser} spec
-- argument. You can also pass it as the `handler` argument to @{on} for
-- options you want to add manually without putting them in the
-- @{OptionParser} spec.
--
-- Beware that, _unlike_ @{required}, this handler will store multiple
-- occurrences of a command-line option as a table **only** when given a
-- `value` function.   Automatically assigned handlers do not do this, so
-- the option will simply be `true` if the option was given one or more
-- times on the command-line.
-- @static
-- @tparam table arglist list of arguments
-- @int i index of last processed element of *arglist*
-- @param[opt] value either a function to process the option argument,
--    or a value to store when this flag is encountered
-- @treturn int index of next element of *arglist* to process
-- @usage
-- parser:on({'--long-opt', '-x'}, parser.flag)
local function flag(self, arglist, i, value)
   local opt = arglist[i]
   if iscallable(value) then
      set(self, opt, value(self, opt, true))
   elseif value == nil then
      local key = self[opt].key
      self.opts[key] = true
   end

   return i + 1
end


--- Option should display help text, then exit.
--
-- This is the handler automatically assigned tooptions that have
-- `--help` in the specification, e.g. `-h, -?, --help`.
-- @static
-- @function help
-- @usage
-- parser:on('-?', parser.help)
local function help(self)
   print(self.helptext)
   exit(0)
end


--- Option should display version text, then exit.
--
-- This is the handler automatically assigned tooptions that have
-- `--version` in the specification, e.g. `-V, --version`.
-- @static
-- @function version
-- @usage
-- parser:on('-V', parser.version)
local function version(self)
   print(self.versiontext)
   exit(0)
end



--[[ =============== ]]--
--[[ Argument Types. ]]--
--[[ =============== ]]--


--- Map various option strings to equivalent Lua boolean values.
-- @table boolvals
-- @field false false
-- @field 0 false
-- @field no false
-- @field n false
-- @field true true
-- @field 1 true
-- @field yes true
-- @field y true
local boolvals = {
   ['false'] = false, ['true'] = true,
   ['0']     = false, ['1']    = true,
   no        = false, yes      = true,
   n         = false, y        = true,
}


--- Return a Lua boolean equivalent of various *optarg* strings.
-- Report an option parse error if *optarg* is not recognised.
--
-- Pass this as the `value` function to @{on} when you want various
-- 'truthy' or 'falsey' option arguments to be coerced to a Lua `true`
-- or `false` respectively in the options table.
-- @static
-- @string opt option name
-- @string[opt='1'] optarg option argument, must be a key in @{boolvals}
-- @treturn bool `true` or `false`
-- @usage
-- parser:on('--enable-nls', parser.optional, parser.boolean)
local function boolean(self, opt, optarg)
   if optarg == nil then
      optarg = '1' -- default to truthy
   end
   local b = boolvals[lower(tostring(optarg))]
   if b == nil then
      return self:opterr(optarg .. ': Not a valid argument to ' ..opt[1] .. '.')
   end
   return b
end


--- Report an option parse error unless *optarg* names an
-- existing file.
--
-- Pass this as the `value` function to @{on} when you want to accept
-- only option arguments that name an existing file.
-- @fixme this only checks whether the file has read permissions
-- @static
-- @string opt option name
-- @string optarg option argument, must be an existing file
-- @treturn string *optarg*
-- @usage
-- parser:on('--config-file', parser.required, parser.file)
local function file(self, opt, optarg)
   local h, errmsg = open(optarg, 'r')
   if h == nil then
      return self:opterr(optarg .. ': ' .. errmsg)
   end
   h:close()
   return optarg
end



--[[ =============== ]]--
--[[ Option Parsing. ]]--
--[[ =============== ]]--


--- Report an option parse error, then exit with status 2.
--
-- Use this in your custom option handlers for consistency with the
-- error output from built-in @{optparse} error messages.
-- @static
-- @string msg error message
local function opterr(self, msg)
   local prog = self.program
   -- Ensure final period.
   if match(msg, '%.$') == nil then
      msg = msg .. '.'
   end
   stderr:write(prog .. ': error: ' .. msg .. '\n')
   stderr:write(prog .. ": Try '" .. prog .. " --help' for help.\n")
   exit(2)
end


------
-- Function signature of an option handler for @{on}.
-- @function on_handler
-- @tparam table arglist list of arguments
-- @int i index of last processed element of *arglist*
-- @param[opt=nil] value additional `value` registered with @{on}
-- @treturn int index of next element of *arglist* to process


--- Add an option handler.
--
-- When the automatically assigned option handlers don't do everything
-- you require, or when you don't want to put an option into the
-- @{OptionParser} `spec` argument, use this function to specify custom
-- behaviour.   If you write the option into the `spec` argument anyway,
-- calling this function will replace the automatically assigned handler
-- with your own.
--
-- When writing your own handlers for @{optparse:on}, you only need
-- to deal with expanded arguments, because combined short arguments
-- (`-xyz`), equals separators to long options (`--long=ARG`) are fully
-- expanded before any handler is called.
-- @function on
-- @tparam[string|table] opts name of the option, or list of option names
-- @tparam on_handler handler function to call when any of *opts* is
--    encountered
-- @param value additional value passed to @{on_handler}
-- @usage
-- -- Don't process any arguments after `--`
-- parser:on('--', parser.finished)
local function on(self, opts, handler, value)
   if type(opts) == 'string' then
      opts = {opts}
   end
   handler = handler or flag -- unspecified options behave as flags

   local args = {}
   for _, optspec in ipairs(opts) do
      gsub(optspec, '(%S+)', function(opt)
         -- 'x' => '-x'
         if len(opt) == 1 then
            opt = '-' .. opt

         -- 'option-name' => '--option-name'
         elseif match(opt, '^[^%-]') then
            opt = '--' .. opt
         end

         if match(opt, '^%-[^%-]+') then
            -- '-xyz' => '-x -y -z'
            for i = 2, len(opt) do
               insert(args, '-' .. sub(opt, i, i))
            end
         else
            insert(args, opt)
         end
      end)
   end

   if nonempty(args) then
      -- strip leading '-', and convert non-alphanums to '_'
      local key = gsub(match(last(args), '^%-*(.*)$'), '%W', '_')

      for _, opt in ipairs(args) do
         self[opt] = {key=key, handler=handler, value=value}
      end
   end
end


------
-- Parsed options table, with a key for each encountered option, each
-- with value set by that option's @{on_handler}.   Where an option
-- has one or more long-options specified, the key will be the first
-- one of those with leading hyphens stripped and non-alphanumeric
-- characters replaced with underscores.   For options that can only be
-- specified by a short option, the key will be the letter of the first
-- of the specified short options:
--
--       {'-e', '--eval-file'} => opts.eval_file
--       {'-n', '--dryrun', '--dry-run'} => opts.dryrun
--       {'-t', '-T'} => opts.t
--
-- Generally there will be one key for each previously specified
-- option (either automatically assigned by @{OptionParser} or
-- added manually with @{on}) containing the value(s) assigned by the
-- associated @{on_handler}.   For automatically assigned handlers,
-- that means `true` for straight-forward flags and
-- optional-argument options for which no argument was given; or else
-- the string value of the argument passed with an option given only
-- once; or a table of string values of the same for arguments given
-- multiple times.
--
--       ./prog -x -n -x => opts = {x=true, dryrun=true}
--       ./prog -e '(foo bar)' -e '(foo baz)'
--             => opts = {eval_file={'(foo bar)', '(foo baz)'}}
--
-- If you write your own handlers, or otherwise specify custom
-- handling of options with @{on}, then whatever value those handlers
-- return will be assigned to the respective keys in `opts`.
-- @table opts


--- Parse an argument list.
-- @tparam table arglist list of arguments
-- @tparam[opt] table defaults table of default option values
-- @treturn table a list of unrecognised *arglist* elements
-- @treturn opts parsing results
local function parse(self, arglist, defaults)
   self.unrecognised, self.opts = {}, {}

   arglist = expandargs(self, arglist)

   local i = 1
   while i > 0 and i <= len(arglist) do
      local opt = arglist[i]

      if self[opt] == nil or match(opt, '^[^%-]') then
         insert(self.unrecognised, opt)
         i = i + 1

         -- Following non-'-' prefixed argument is an optarg.
         if i <= len(arglist) and match(arglist[i], '^[^%-]') then
            insert(self.unrecognised, arglist[i])
            i = i + 1
         end

      -- Run option handler functions.
      else
         assert(iscallable(self[opt].handler))

         i = self[opt].handler(self, arglist, i, self[opt].value)
      end
   end

   -- Merge defaults into user options.
   self.opts = merge(defaults or {}, self.opts)

   -- metatable allows `io.warn` to find `parser.program` when assigned
   -- back to _G.opts.
   return self.unrecognised, setmetatable(self.opts, {__index=self})
end


--- Take care not to register duplicate handlers.
-- @param current current handler value
-- @param new new handler value
-- @return `new` if `current` is nil
local function set_handler(current, new)
   assert(current == nil, 'only one handler per option')
   return new
end


local function _init(self, spec)
   local parser = {}

   parser.versiontext, parser.version, parser.helptext, parser.program =
      match(spec, '^([^\n]-(%S+)\n.-)%s*([Uu]sage: (%S+).-)%s*$')

   if parser.versiontext == nil then
      error("OptionParser spec argument must match '<version>\\n" ..
             "...Usage: <program>...'")
   end

   -- Collect helptext lines that begin with two or more spaces followed
   -- by a '-'.
   local specs = {}
   gsub(parser.helptext, '\n  %s*(%-[^\n]+)', function(spec)
      insert(specs, spec)
   end)

   -- Register option handlers according to the help text.
   for _, spec in ipairs(specs) do
      -- append a trailing space separator to match %s in patterns below
      local options, spec, handler = {}, spec .. ' '

      -- Loop around each '-' prefixed option on this line.
      while match(spec, '^%-[%-%w]') do

         -- Capture end of options processing marker.
         if match(spec, '^%-%-,?%s') then
            handler = set_handler(handler, finished)

         -- Capture optional argument in the option string.
         elseif match(spec, '^%-[%-%w]+=%[.+%],?%s') then
            handler = set_handler(handler, optional)

         -- Capture required argument in the option string.
         elseif match(spec, '^%-[%-%w]+=%S+,?%s') then
            handler = set_handler(handler, required)

         -- Capture any specially handled arguments.
         elseif match(spec, '^%-%-help,?%s') then
            handler = set_handler(handler, help)

         elseif match(spec, '^%-%-version,?%s') then
            handler = set_handler(handler, version)
         end

         -- Consume argument spec, now that it was processed above.
         spec = gsub(spec, '^(%-[%-%w]+)=%S+%s', '%1 ')

         -- Consume short option.
         local _, c = gsub(spec, '^%-([-%w]),?%s+(.*)$', function(opt, rest)
            if opt == '-' then
              opt = '--'
            end
            insert(options, opt)
            spec = rest
         end)

         -- Be careful not to consume more than one option per iteration,
         -- otherwise we might miss a handler test at the next loop.
         if c == 0 then
            -- Consume long option.
            gsub(spec, '^%-%-([%-%w]+),?%s+(.*)$', function(opt, rest)
               insert(options, opt)
               spec = rest
            end)
         end
      end

      -- Unless specified otherwise, treat each option as a flag.
      on(parser, options, handler or flag)
   end

   return setmetatable(parser, getmetatable(self))
end


--- Signature for initialising a custom OptionParser.
--
-- Read the documented options from *spec* and return custom parser that
-- can be used for parsing the options described in *spec* from a run-time
-- argument list.   Options in *spec* are recognised as lines that begin
-- with at least two spaces, followed by a hyphen.
-- @static
-- @function OptionParser_Init
-- @string spec option parsing specification
-- @treturn OptionParser a parser for options described by *spec*
-- @usage
-- customparser = optparse(optparse_spec)


return setmetatable({
   --- Module table.
   -- @table optparse
   -- @string version release version identifier


   --- OptionParser prototype object.
   --
   -- Most often, after instantiating an @{OptionParser}, everything else
   -- is handled automatically.
   --
   -- Then, calling `parser:parse` as shown below saves unparsed arguments
   -- into `_G.arg` (usually filenames or similar), and `_G.opts` will be a
   -- table of successfully parsed option values. The keys into this table
   -- are the long-options with leading hyphens stripped, and non-word
   -- characters turned to `_`.   For example if `--another-long` had been
   -- found in the initial `_G.arg`, then `_G.opts` will have a key named
   -- `another_long`, with an appropriate value.   If there is no long
   -- option name, then the short option is used, i.e. `_G.opts.b` will be
   -- set.
   --
   -- The values saved against those keys are controlled by the option
   -- handler, usually just `true` or the option argument string as
   -- appropriate.
   -- @object OptionParser
   -- @tparam OptionParser_Init _init initialisation function
   -- @string program the first word following 'Usage:' from *spec*
   -- @string version the last white-space delimited word on the first line
   --    of text from *spec*
   -- @string versiontext everything preceding 'Usage:' from *spec*, and
   --    which will be displayed by the @{version} @{on_handler}
   -- @string helptext everything including and following 'Usage:' from
   --    *spec* string and which will be displayed by the @{help}
   --    @{on_handler}
   -- @usage
   -- local optparse = require 'optparse'
   --
   -- local optparser = optparse [[
   -- any text VERSION
   -- Additional lines of text to show when the --version
   -- option is passed.
   --
   -- Several lines or paragraphs are permitted.
   --
   -- Usage: PROGNAME
   --
   -- Banner text.
   --
   -- Optional long description text to show when the --help
   -- option is passed.
   --
   -- Several lines or paragraphs of long description are permitted.
   --
   -- Options:
   --
   --   -b                       a short option with no long option
   --       --long               a long option with no short option
   --       --another-long       a long option with internal hypen
   --       --really-long-option-name
   --                            with description on following line
   --   -v, --verbose            a combined short and long option
   --   -n, --dryrun, --dry-run  several spellings of the same option
   --   -u, --name=USER          require an argument
   --   -o, --output=[FILE]      accept an optional argument
   --       --version            display version information, then exit
   --       --help               display this help, then exit
   --
   -- Footer text.   Several lines or paragraphs are permitted.
   --
   -- Please report bugs at bug-list@yourhost.com
   -- ]]
   --
   -- -- Note that `std.io.die` and `std.io.warn` will only prefix messages
   -- -- with `parser.program` if the parser options are assigned back to
   -- -- `_G.opts`:
   -- _G.arg, _G.opts = optparser:parse(_G.arg)
   prototype = setmetatable({
      -- Prototype initial values.
      opts        = {},
      helptext    = '',
      program     = '',
      versiontext = '',
      version     = 0,
   }, {
      _type = 'OptionParser',

      __call = _init,

      --- @export
      __index = {
         boolean  = boolean,
         file     = file,
         finished = finished,
         flag     = flag,
         help     = help,
         optional = optional,
         required = required,
         version  = version,

         on       = on,
         opterr   = opterr,
         parse    = parse,
      },
   }),
}, {
   --- Metamethods
   -- @section Metamethods

   _type = 'Module',


   -- Pass through options to the OptionParser prototype.
   __call = function(self, ...)
      return self.prototype(...)
   end,


   --- Lazy loading of optparse submodules.
   -- Don't load everything on initial startup, wait until first attempt
   -- to access a submodule, and then load it on demand.
   -- @function __index
   -- @string name submodule name
   -- @treturn table|nil the submodule that was loaded to satisfy the missing
   --    `name`, otherwise `nil` if nothing was found
   -- @usage
   -- local optparse = require 'optparse'
   -- local version = optparse.version
   __index = function(self, name)
      local ok, t = pcall(require, 'optparse.' .. name)
      if ok then
         rawset(self, name, t)
         return t
      end
   end,
})
