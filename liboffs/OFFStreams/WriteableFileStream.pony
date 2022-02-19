use "Exception"
use "files"
use "Streams"
use "Buffer"

actor WriteableFileStream is WriteablePushStream[Buffer iso]
  var _isDestroyed: Bool = false
  let _file: File
  let _subscribers': Subscribers

  new create(file: File iso) =>
    _subscribers' = Subscribers(3)
    _file = consume file

  fun ref _subscribers(): Subscribers=>
    _subscribers'

  fun _destroyed(): Bool =>
    _isDestroyed

  be write(data: Buffer iso) =>
    if _destroyed() then
      _notifyError(Exception("Stream has been destroyed"))
    else
      let data': Buffer val = consume data
      let ok = _file.write(data'.data)
      if not ok then
        _notifyError(Exception("Failed to write data"))
      end
    end

  be piped(stream: ReadablePushStream[Buffer iso] tag) =>
    if _destroyed() then
      _notifyError(Exception("Stream has been destroyed"))
    else
      let dataNotify: DataNotify[Buffer iso] iso = object iso is DataNotify[Buffer iso]
        let _stream: WriteableFileStream tag = this
        fun ref apply(data': Buffer iso) =>
          _stream.write(consume data')
      end
      stream.subscribe(consume dataNotify)
      let errorNotify: ErrorNotify iso = object iso is ErrorNotify
        let _stream: WriteableFileStream tag = this
        fun ref apply(ex: Exception) => _stream.destroy(ex)
      end
      stream.subscribe(consume errorNotify)
      let completeNotify: CompleteNotify iso = object iso is CompleteNotify
        let _stream: WriteableFileStream tag = this
        fun ref apply() => _stream.close()
      end
      stream.subscribe(consume completeNotify)
      let closeNotify: CloseNotify iso = object iso  is CloseNotify
        let _stream: WriteableFileStream tag = this
        fun ref apply () =>
          _stream.close()
      end
      let closeNotify': CloseNotify tag = closeNotify
      stream.subscribe(consume closeNotify)
      _notifyPiped()
    end

  be destroy(message: (String | Exception)) =>
    match message
      | let message' : String =>
        _notifyError(Exception(message'))
      | let message' : Exception =>
        _notifyError(message')
    end
    _isDestroyed = true
    _file.dispose()
    let subscribers: Subscribers = _subscribers()
    subscribers.clear()

  be close() =>
    if not _destroyed() then
      _notifyFinished()
      _isDestroyed = true
      _file.dispose()
      _notifyClose()
      let subscribers: Subscribers = _subscribers()
      subscribers.clear()
    end
