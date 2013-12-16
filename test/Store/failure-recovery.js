'use strict';

var expect = require('../util/').expect;
var uuid = require('node-uuid');

var heartbeatId = 0;
describe('Failed Store txns', function () {
  describe('in real server', function () {
    var port, store, server, socket;
    before(function () {
      var racer = require('../../');
      var http = require('http');

      port = ~~(1024 + 30000 + Math.random() * 20000);
      server = http.createServer();

      racer.use(require('../db-async-memory.js'));

      store = racer.createStore({ listen: server, db: { type: 'AsyncMemory', errorPaths: /error/ } });

      server.listen(port);

      socket = require('socket.io-client').connect(
        ':' + port,
        { query: 'clientId=Heartbeat-' + (++heartbeatId), 'force new connection': true }
        );
    });

    after(function (done) {
      socket.disconnect();
      server.close(done);
    });
    it('should not break txn queue', function (done) {
      runTxn('error.first', 1, function (err, args) {
        expect(err).to.match(/Boom/);

        runTxn('error.second', 1, function (err, args) {
          expect(err).to.match(/Boom/);

          runTxn('normal.path', 1, done);
        });
      });
    });

    function runTxn(path, value, cb) {
      var ourTxnId = "txnId." + uuid();

      var okHandler = function (args) {
        /*ver, id, method, opArgs*/
        socket.removeListener('txnOk', okHandler);
        socket.removeListener('txnErr', errorHandler);

        expect(args[1]).to.be(ourTxnId);
        cb(null, args);
      };

      socket.on('txnOk', okHandler);

      var errorHandler = function (err, txnId) {
        socket.removeListener('txnOk', okHandler);
        socket.removeListener('txnErr', errorHandler);

        expect(txnId).to.be(ourTxnId);
        cb(err);
      }

      socket.on('txnErr', errorHandler);

      socket.emit('txn', [-1, ourTxnId, "set", [path, value], -1]);
    }
  });
});