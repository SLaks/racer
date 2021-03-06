/** WARNING
 * All racer modules for the browser should be included in racer.coffee and not
 * in this file.
 */

var configuration = require('./configuration')

// Static isReady and model variables are used, so that the ready function can
// be called anonymously. This assumes that only one instance of Racer is
// running, which should be the case in the browser.
var IS_READY
  , model;

exports = module.exports = plugin;
exports.useWith = { server: false, browser: true };
exports.decorate = 'racer';

function plugin (racer) {
  var envs = ['browser'];
  configuration.makeConfigurable(racer, envs);

  racer.init = function (tuple, socket) {
    var clientId  = tuple[0]
      , memory    = tuple[1]
      , count     = tuple[2]
      , onLoad    = tuple[3]
      , startId   = tuple[4]
      , ioUri     = tuple[5]
      , ioOptions = tuple[6]
      , flags     = tuple[7]

    model = new this.protected.Model;
    model._clientId = clientId;
    model._startId  = startId;
    model._memory.init(memory);
    model._count = count;
    model.flags = flags;

    // TODO: Configuration methods don't account for this env value not being
    // available right away
    envs.push(model.flags.nodeEnv);

    // Suppress change events during initial initialization.
    // Side-effects resulting from change handlers should be
    // bundled along with everything else. (or run after all
    // bundled sets to avoid extra work for each operation)
    model._silent = true;
    for (var i = 0, l = onLoad.length; i < l; i++) {
      var item = onLoad[i]
        , method = item.shift();
      model[method].apply(model, item);
    }
    model._silent = false;

    racer.emit('init', model);

    // TODO If socket is passed into racer, make sure to add clientId query param
    if (ioOptions.query)
      ioOptions.query += '&clientId=' + encodeURIComponent(clientId);
    else
      ioOptions.query = 'clientId=' + encodeURIComponent(clientId);
    model._setSocket(socket || io.connect(ioUri, ioOptions));

    model.connectTo = function (newUri) {
      // If we already have a different socket,
      // wait for it to fully disconnect first.
      if (model.connected) {
        model.socket.once("disconnect", model.connectTo.bind(model, newUri));
        model.socket.disconnect();
        return;
      }
      // This is necessary in case we reconnect to an earlier
      // server; the server needs to get a new connection.
      ioOptions['force new connection'] = true;
      model._setSocket(io.connect(newUri, ioOptions));
    };

    IS_READY = true;
    racer.emit('ready', model);
    return racer;
  };

  racer.ready = function (onready) {
    return function () {
      if (IS_READY) return onready(model);
      racer.on('ready', onready);
    };
  }
}
