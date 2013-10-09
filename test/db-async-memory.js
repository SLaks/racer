// Copied from adapters/db-memory, and modified to run all callbacks asynchronously.

var Memory = require('../lib/Memory')
  , util = require('../lib/util')
  , mergeAll = util.mergeAll
  , deepCopy = util.deepCopy
  , Query = require('../lib/descriptor/query/MemoryQuery')
  , MUTATORS = ['set', 'del' ,'push', 'unshift', 'insert', 'pop', 'shift', 'remove', 'move']
  , routePattern = /^[^.]+(?:\.[^.]+)?(?=\.|$)/
  ;

exports = module.exports = plugin;
exports.useWith = { server: true, browser: false };
exports.decorate = 'racer';

exports.adapter = DbMemory;

function plugin (racer) {
  racer.registerAdapter('db', 'AsyncMemory', DbMemory);
}

function DbMemory (opts) {
  this.errorPaths = opts.errorPaths;
  this._flush();
}

mergeAll(DbMemory.prototype, Memory.prototype, {
  Query: Query

, _flush: Memory.prototype.flush

, flush: function (cb) {
    this._flush();
    cb(null);
  }

, setVersion: Memory.prototype.setVersion

, _get: Memory.prototype.get
, get: function (path, cb) {
    var val;
    try {
      val = this._get(path);
    } catch (err) {
      return cb(err);
    }
    cb(null, deepCopy(val), this.version);
  }

, setupRoutes: function (store) {
    var self = this;
    MUTATORS.forEach( function (method) {
      store.route(method, '*', -1000, function (path/*, args..., ver, done, next*/) {
        var i = arguments.length - 3;
        var args = Array.prototype.slice.call(arguments, 1, i);
        var ver = arguments[i++];
        var done = arguments[i++];
        var next = arguments[i++];
        args = deepCopy(args);
        var match = routePattern.exec(path);
        var docPath = match && match[0];
        var topDocPath = docPath.split('.').slice(0, 2).join('.');

        if (self.errorPaths && self.errorPaths.test(path))
          return done(new Error("Boom!"));

        self.get(topDocPath, function (err, topDoc) {
          topDoc = deepCopy(topDoc);
          self.get(docPath, function (err, doc) {
            if (err) return done(err);
            var oldDoc = topDoc;
            try {
              self[method].apply(self, [path].concat(args, ver, null));
            } catch (err) {
              return done(err, oldDoc);
            }
            process.nextTick(function () { done(null, oldDoc); });
          });
        });
      });
    });

    store.route('get', '*', -1000, function getFn (path, done, next) {
      process.nextTick(function () { self.get(path, done); });
    });
  }

});
