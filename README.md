![TARBALLIFY ALL THE THINGS!](/dodo/node-tarballify/raw/master/23182620.jpg)

Put all the things from your server in one tarball.

```javascript
var fs = require('fs')
var path = require('path')
var tarballify = require('tarballify')

console.log("creating new tarball …")
var tarball = tarballify('./server.js', {
    dirname:__dirname,
})
    .register(".node", function (body, file) {
        console.log("skip binary file:", file)
        return "skip binary"
    })
    .on('error', console.error.bind(console))
    .on('wait', function(){console.log("waiting for tarball to finish …")})
    .on('append', function(f){console.log("append",f.props.size, "\t",f.path)})
    .on('close', function(){console.log("done.")})
    .on('syntaxError', console.error.bind(console))
tarball.pipe(fs.createWriteStream(path.join(__dirname, "test.tar.gz")))

console.log("setup ok.")
tarball.end()
```
