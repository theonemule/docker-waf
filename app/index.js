var express = require('express');
var app = express();

app.use(function(req, res, next) {

    console.log(req.originalUrl);
    next();
}, express.static('public'));


app.listen(80);
console.log('Listening on port 80');
