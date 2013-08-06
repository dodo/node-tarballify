fs = require 'fs'
path = require 'path'
util = require 'util'
{ EventEmitter } = require 'events'
{ Pack:Tarball } = require 'tarball'
BufferStream = require 'bufferstream'
detective = require 'detective'
resolve = require 'resolve'
deputy = require 'deputy'
commondir = require 'commondir'
nub = require 'nub'

module.exports = (opts) -> new Wrap(opts)

idFromPath = (path) -> path.replace(/\\/g, '/')
pkgbasedir = (dir) ->
    dn = path.dirname(dir)
    while path.basename(dn) isnt "node_modules"
        dir = dn
        dn = path.dirname(dir)
    return dir
evalExpressions = (expressions, ctx) ->
    [res, haserr] = [[], no]
    output = ["Expressions in require() statements in #{ctx.__filename}"]
    for ex in expressions
        # lets try to eval the exp before we completely give up
        try # veryCrude™
            ev = eval("with(ctx){#{ex}}", ctx)
            res.push(ev) if typeof ev is 'string'
            output.push("    `#{ex}` → #{JSON.stringify ev}")
        catch err
            output.push("    require(#{ex})  #{err?.message or ""}")
            haserr = yes
    @emit(haserr and 'error' or 'warn', output.join("\n"))
    return res


class Wrap extends EventEmitter
    constructor: (opts = {}) ->
        home = process.env.HOME or process.env.USERPROFILE
        opts.cache ?= on if home?

        if opts.cache
            if typeof opts.cache is 'boolean'
                file = path.join(home, '.config/tarballify/cache.json')
                @detective = deputy(file)
            else
                @detective = deputy(opts.cache)
        else
            @detective = detective

        @tarball = new Tarball {noProprietary:yes},
            compress:on
            defaults:
                uname:'www'
                gname:'nogroup'
                uid: 1000
                gid: 1000
                mode: 0o0666
        @tarball.on('error', @emit.bind(this, 'error'))
        @tarball.setMaxListeners(0)

        @working = no
        @dirname = opts.dirname ? process.cwd()
        @exports = opts.exports
        @debug = opts.debug
        @piped = no

        @skip = []
        @queue = []
        @files = []
        @filters = []

        @extensions = [ '.js', '.node' ]

    use: (fn) ->
        fn(this, this)
        return this

    has: (file) ->
        return yes if @files[file]
        return Object.keys(@files).some((key) => @files[key].target is file)

    end: () =>
        @installscript = yes unless Object.keys(@skip).length
        unless @installscript # veryPrimitive™
            # generate an installscript to get all nodejs bindings with npm
            @installscript = yes
            src = [
                "#!/bin/sh"
                "# auto generated file by https://github.com/dodo/node-tarballify"
                "cwd=`pwd`"
                "# find where this file really is by dereferencing the symlink(s)."
                "this=$0"
                "cd `dirname $this`"
                "while [ -n \"`readlink $this`\" ] ; do"
                "\tthis=`readlink $this`"
                "\tcd `dirname $this`"
                "done"
                "dir=`pwd`"
                "# install party"
            ]
            islastdir = no
            for pkgname,pkgs of @skip
                src.push("echo 'install #{pkgname} …'")
                for pkgpath in nub(pkgs)
                    parentpkgpath = path.join(pkgpath, "../..")
                    unless pkgpath isnt @dirname and parentpkgpath isnt @dirname
                        src.push("npm install #{pkgname}")
                        islastdir = no
                        continue
                    src.push("cd #{path.relative(@dirname, parentpkgpath)}")
                    src.push("npm install #{pkgname}")
                    src.push("cd $dir")
                    islastdir = yes
            src.pop() if islastdir
            src.push("# go back where we came from")
            src.push("cd $cwd")
            src.push("echo 'done.'")
            entry = @append("build-deps", src.join("\n"), mode:0o0777)
            entry.name = "main"
        if @working
            @ending = yes
            @emit('wait')
        else
            @tarball.end()

    pipe: (dests...) ->
        console.warn("there might be dragons when you pipe twice.") if @piped
        @piped = yes
        src = @tarball
        while (dst = dests.shift())?
            src = src.pipe(dst).on('error', @emit.bind(this, 'error'))
        src.on('close', @emit.bind(this, 'close'))
        @emit('pipe')
        return src

    work: (job) ->
        if job?
            @working = yes
            process.nextTick(job.bind(this, => @work(@queue.shift())))
        else
            @working = no
            @end() if @ending

    _push: (job) ->
        if @working
            @queue.push(job)
        else
            @work(job)

    append: (file, content, opts = {}, callback) ->
        console.warn("WARN: no output specified.") unless @piped
        dirname = opts.dirname ? @dirname
        @files[file] = entry = {file}
        file = path.resolve(dirname, file)
        stream = new BufferStream disabled:yes # no splitting needed
        stream.path = entry.file
        unless opts.size?
            if path.existsSync(file)
                stats = fs.statSync(file)
                opts.size  = stats.size
                opts.mode ?= parseInt(stats.mode.toString(8)[2 ..])
            else if typeof content is 'string'
                opts.size = new Buffer(content).length
            @emit('error', "no size for #{file}") unless opts.size?
        stream.props = size:opts.size
        stream.props.mode = opts.mode if opts.mode?
        @_push (done) ->
            return done() if @skip[entry.name]
            @emit('append', stream, entry)
            @tarball.append(stream, done)
            content or= fs.createReadStream(file)
            if typeof content is 'string'
                stream.end(content, opts.encoding ? 'utf-8')
            else
                content.pipe(stream)
        return entry

    register: (ext, fn) ->
        if typeof ext is 'object'
            fn = ext.wrapper
            ext = ext.extension
        else if fn
            @extensions.push(ext)
            @filters.push (body, file) =>
                if file.slice(-ext.length) is ext
                    fn.call(this, body, file)
                else body
        else
            @filters.push(ext)
        return this

    readFile: (file) ->
        source = undefined
        body = fs.readFileSync(file, 'utf-8')
        for fn in @filters
            res = fn.call(this, body, file)
            if res?.source?
                {source, body} = res
            else
                body = res
        return {source, body}

    addEntry: (filename, opts = {}, callback) ->
        dirname = opts.dirname ? @dirname
        file = path.resolve(dirname, filename)
        if opts.body?
            {source, body} = opts
        else
            {source, body} = @readFile(file)
        console.log "addEntry", opts.body?, typeof(source), typeof(body)

        try required = @detective.find(body)
        catch err
            err.message = "Error while loading entry file " +
                "#{JSON.stringify(file)}: #{err.message}"
            process.nextTick( => @emit('syntaxError', err))
            return this
        if required.expressions.length
            exps = evalExpressions.call this, required.expressions,
                process:process
                __dirname:dirname
                __filename:file
            required.strings = required.strings.concat(exps)


        dirname = path.dirname(file)
        entry = @append(filename, source ? body, {dirname})
        entry.target = opts.target if opts.target?
        entry.name = name = opts.name ? "main"

        for req in required.strings
            params = {dirname, name, fromFile:entry.file}
            if opts.target and /^[.\/]/.test(req)
                params.target = path.resolve(path.dirname(opts.target), req)
            @require(req, params)
        return this

    resolver: (file, basedir) ->
        resolve.sync(file, {basedir, @extensions})

    require: (mfile, opts = {}) ->
        opts.dirname ?= @dirname
        return this unless not @has(mfile) and
            not resolve.isCore(mfile)      and
            not (opts.target? and @has(opts.target))
        moduleError = (msg) ->
            "#{msg}: #{JSON.stringify mfile} " +
                "from directory #{JSON.stringify opts.dirname}" +
                (opts.fromFile? and " while processing file #{opts.fromFile}" or "")
        opts.file = mfile if opts.body
        unless opts.file
            try
                if path.normalize(path.resolve(mfile)) is path.normalize(mfile)
                    normPath = path.normalize(mfile)
                else
                    normPath = mfile
                opts.file = @resolver(normPath, opts.dirname)
            catch err
                msg = moduleError("Cannot find module. #{err?.message}")
                @emit('error', msg)
        return this if @has(opts.file)
        dirname = path.dirname(opts.file)
        pkgfile = path.join(dirname, 'package.json')
        unless /^(\.\.?)?\//.test(mfile)
            try pkgfile = resolve.sync path.join(mfile, 'package.json'),
                basedir:dirname
            catch err # nothing
        if pkgfile
            if @files[pkgfile]
                pkgname = @files[pkgfile].name
            else
                unless path.existsSync(pkgfile)
                    pkgfile = null
                else
                    pkgbody = fs.readFileSync(pkgfile, 'utf-8')
                    try
                        npmpkg = JSON.parse(pkgbody)
                        pkgname = npmpkg?.name
                    catch err #  ignore broken package.jsons just like node
                    pkgjson = @append(pkgfile, pkgbody, {dirname})
                    pkgjson.name = pkgname ? opts.name
        name = pkgname ? opts.name

        ext = ".node"
        if opts.file.slice(-ext.length) is ext
            unless name is "main"
                dir = pkgbasedir(opts.file)
            @emit("skip", {file:opts.file, name, dirname:dir ? dirname})
            (@skip[name] ?= []).push(dir ? @dirname)
            return this
        if opts.body?
            {source, body} = opts
        else
            {source, body} = @readFile(opts.file)

        try required = @detective.find(body)
        catch err
            err.message = "Error while loading file " +
                "#{JSON.stringify(opts.file)}: #{err.message}"
            process.nextTick( => @emit('syntaxError', err))
            return this
        if required.expressions.length
            exps = evalExpressions.call this, required.expressions,
                process:process
                __dirname:dirname
                __filename:opts.file
            required.strings = required.strings.concat(exps)

        entry = @append(opts.file, source ? body, {dirname})
        entry.target = opts.target
        entry.name = name

        for req in nub(required.strings)
            params = {dirname, name, fromFile:entry.file}
            if opts.target and /^[.\/]/.test(req)
                # not a real directory on the filesystem; just using the path
                # module to get rid of the filename.
                targetDir = path.dirname(opts.target)
                # not a real filename; just using the path module to deal with
                # relative paths.
                reqFilename = path.resolve(targetDir, req)
                # get rid of drive letter on Windows; replace it with '/'
                reqFilenameWithoutDriveLetter = if /^[A-Z]:\\/.test(reqFilename)
                        '/' + reqFilename.substring(3)
                    else reqFilename

                params.target = idFromPath(reqFilenameWithoutDriveLetter)
            @require(req, params)
        return this


