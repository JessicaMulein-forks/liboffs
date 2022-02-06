use "Streams"
use "Blake2b"
use "Buffer"
use "Exception"
use "collections"
use "Base58"
use "../BlockCache"

trait FileHashNotify is Notify
  fun ref apply(fileHash: Buffer val)
  fun box hash(): USize =>
    51

primitive FileHashKey is FileHashNotify
  fun ref apply(fileHash: Buffer val) => None

actor WriteableOffStream[B: BlockType] is TransformPushStream[Tuple val, Buffer iso]
  let _bc: BlockCache[B]
  let _tc: TupleCache
  var _accumulator: Buffer iso
  var _readable: Bool = false
  var _isDestroyed: Bool = false
  let _hash: Blake2b
  let _subscribers': Subscribers
  var _pipeNotifiers': (Array[Notify tag] iso | None) = None
  var _isPiped: Bool = false
  let _blockSize: USize
  let _recipes: Array[BlockRecipe[B] tag]
  var _currentRecipe: BlockRecipe[B] tag
  var _currentRecipeNotifiers: Array[Notify tag] = Array[Notify tag](4)
  let _bs: BlockService[B]
  var _originBlocks: Array[Block[B]] = Array[Block[B]](5)
  var _tupleSize: USize
  var _finalBlock: (Block[B] tag | None) = None

  new create(bc: BlockCache[B], tc: TupleCache, recipes: Array[BlockRecipe[B] tag] iso, digestSize: USize, tupleSize: USize) =>
    _subscribers' = Subscribers(3)
    _hash = Blake2b(digestSize)
    _bc = bc
    _tc = tc
    _bs = BlockService[B]
    _blockSize = BlockSize[B]()
    _accumulator = recover Buffer(_blockSize) end
    _recipes = consume recipes
    _tupleSize = tupleSize
    _currentRecipe = try _recipes.pop()? else NewBlocksRecipe[B](_bc) end

  fun _isFinalBlock(block: Block[B] tag) : Bool =>
    match _finalBlock
      | None => false
      | let finalBlock: Block[B] tag =>
        finalBlock is block
    end

  fun ref _subscribers(): Subscribers =>
    _subscribers'

  fun _destroyed(): Bool =>
    _isDestroyed

  fun readable(): Bool =>
    _readable

  fun ref _piped(): Bool =>
    _isPiped

  fun ref _pipeNotifiers(): (Array[Notify tag] iso^ | None) =>
    _pipeNotifiers' = None

  fun ref _subscriberCount[A: Notify](): USize =>
    let subscribers: Subscribers = _subscribers()
    try
      iftype A <: ThrottledNotify then
        subscribers(ThrottledKey)?.size()
      elseif A <: UnthrottledNotify then
        subscribers(ThrottledKey)?.size()
      elseif A <: ErrorNotify then
        subscribers(ErrorKey)?.size()
      elseif A <: PipedNotify then
        subscribers(PipedKey)?.size()
      elseif A <: UnpipedNotify then
        subscribers(UnpipedKey)?.size()
      elseif A <: PipeNotify then
        subscribers(PipeKey)?.size()
      elseif A <: UnpipeNotify then
        subscribers(UnpipeKey)?.size()
      elseif A <: DataNotify[Tuple val] then
        subscribers(DataKey[Tuple val])?.size()
      elseif A <: ReadableNotify then
        subscribers(ReadableKey)?.size()
      elseif A <: CompleteNotify then
        subscribers(CompleteKey)?.size()
      elseif A <: FinishedNotify then
        subscribers(FinishedKey)?.size()
      elseif A <: EmptyNotify then
        subscribers(EmptyKey)?.size()
      elseif A <: OverflowNotify then
        subscribers(OverflowKey)?.size()
      elseif A <: FileHashNotify then
        subscribers(FileHashKey)?.size()
      else
        0
      end
    else
      0
    end

  be _recipeError(ex: Exception) =>
    _notifyError(ex)

  fun ref _registerRecipe() =>
    let errorNotify: ErrorNotify iso = object iso is ErrorNotify
      let _stream: WriteableOffStream[B] tag = this
      fun apply(ex: Exception) =>
        _stream._recipeError(ex)
        _stream._unregisterRecipe()
    end
    let errorNotify': ErrorNotify tag = errorNotify
    _currentRecipeNotifiers.push(errorNotify')

    let readableNotify: ReadableNotify iso = object iso is ReadableNotify
      let _stream: WriteableOffStream[B] = this
      fun apply() =>
        None
    end
    let readableNotify': ReadableNotify tag = readableNotify
    _currentRecipeNotifiers.push(readableNotify')
    let closeNotify: CloseNotify iso = object iso is CloseNotify
      let _stream: WriteableOffStream[B] = this
      fun apply() =>
        _stream._unregisterRecipe()
    end
    let closeNotify': CloseNotify tag = closeNotify
    _currentRecipeNotifiers.push(closeNotify')
    match _currentRecipe
      | let currentRecipe: BlockRecipe[B] tag =>
        currentRecipe.subscribe(consume errorNotify)
        currentRecipe.subscribe(consume readableNotify)
        currentRecipe.subscribe(consume closeNotify)
    end

  be _createFinalBlock() =>
    if _destroyed() then
      _notifyError(Exception("Stream has been destroyed"))
    else
      let hash: Array[U8] iso = _hash.digest()
      _notifyFileHash(recover Buffer (consume hash) end)
      if _accumulator.size() > 0 then
        try
          let originBlock: Block[B] = _bs.newBlock(_accumulator = recover Buffer(0) end)?
          _finalBlock = originBlock
          _originBlocks.push(originBlock)
          _getRandomBlocks()
          if not _readable then
            _readable = true
            _notifyReadable()
          end
        else
          destroy(Exception("Failed to create final block"))
        end
      else
        _notifyFinished()
        _notifyComplete()
        _close()
      end
    end

  be _unregisterRecipe() =>
    match _currentRecipe
      | let currentRecipe: BlockRecipe[B] tag =>
        for notify in _currentRecipeNotifiers.values() do
          currentRecipe.unsubscribe(notify)
        end
    end
    _currentRecipeNotifiers.clear()
    _currentRecipe = try _recipes.pop()? else NewBlocksRecipe[B](_bc) end
    _registerRecipe()


  fun ref _notifyFileHash(fileHash: Buffer val) =>
    try
      let subscribers: Subscribers = _subscribers()
      let onces = Array[USize](subscribers.size())
      var i: USize = 0
      for notify in subscribers(FileHashKey)?.values() do
        match notify
        |  (let notify': FileHashNotify, let once: Bool) =>
            notify'(fileHash)
            if once then
              onces.push(i)
            end
        end
        i = i + 1
      end
      if onces.size() > 0 then
        _discardOnces(subscribers(FileHashKey)?, onces)
      end
      subscribers.clear()
    end

  be piped(stream: ReadablePushStream[Buffer iso] tag) =>
    if _destroyed() then
      _notifyError(Exception("Stream has been destroyed"))
    else
      let dataNotify: DataNotify[Buffer iso] iso = object iso is DataNotify[Buffer iso]
        let _stream: WriteableOffStream[B] tag = this
        fun ref apply(data': Buffer iso) =>
          _stream.write(consume data')
      end
      stream.subscribe(consume dataNotify)
      let errorNotify: ErrorNotify iso = object iso is ErrorNotify
        let _stream: WriteableOffStream[B] tag = this
        fun ref apply(ex: Exception) => _stream.destroy(ex)
      end/*
      stream.subscribe(consume errorNotify)
      let completeNotify: CompleteNotify iso = object iso is CompleteNotify
        let _stream: TransformPushStream[Tuple val, Buffer iso] = this
        fun ref apply() =>
          _stream.push()
      end
      stream.subscribe(consume completeNotify)*/
      let closeNotify: CloseNotify iso = object iso  is CloseNotify
        let _stream: WriteableOffStream[B] tag = this
        fun ref apply () => _stream._createFinalBlock()
      end
      let closeNotify': CloseNotify tag = closeNotify
      stream.subscribe(consume closeNotify)
      _notifyPiped()
    end

  be pipe(stream: WriteablePushStream[Tuple val] tag) =>
    if _destroyed() then
      _notifyError(Exception("Stream has been destroyed"))
    else
      let pipeNotifiers: Array[Notify tag] iso = try
         _pipeNotifiers() as Array[Notify tag] iso^
      else
        let pipeNotifiers' = recover Array[Notify tag] end
        consume pipeNotifiers'
      end

      let errorNotify: ErrorNotify iso = object iso  is ErrorNotify
        let _stream: WriteableOffStream[B] tag = this
        fun ref apply (ex: Exception) => _stream.destroy(ex)
      end
      let errorNotify': ErrorNotify tag = errorNotify
      pipeNotifiers.push(errorNotify')
      stream.subscribe(consume errorNotify)

      _pipeNotifiers' = consume pipeNotifiers
      stream.piped(this)
      _isPiped = true
      _notifyPipe()
    end

  be push() =>
    None

  be write(data: Buffer iso) =>
    if _destroyed() then
      _notifyError(Exception("Stream has been destroyed"))
    else
      let data': Buffer val = consume data
      _hash.update(data'.data)
      if data'.size() > _blockSize then
        try
          let len: USize = _blockSize - _accumulator.size()
          let stop: USize = (data'.size() - len) / _blockSize
          let remainder: USize = (data'.size() - len) % _blockSize
          _accumulator.append(data', 0, len)
          var originBlock: Block[B] = _bs.newBlock(_accumulator = recover data'.slice((data'.size() - remainder)) end)?
          _originBlocks.push(originBlock)
          _getRandomBlocks()
          if not _readable then
            _readable = true
            _notifyReadable()
          end

          for i in Range(0, stop) do
            originBlock = _bs.newBlock(recover data'.slice((len  + (_blockSize * i)), _blockSize) end)?
            _originBlocks.push(originBlock)
          end
        else
          destroy(Exception("Failed to Create Origin Block"))
          return
        end
      elseif (data'.size() + _accumulator.size()) < _blockSize then
        _accumulator.append(data')
      else
        let len: USize = _blockSize - _accumulator.size()
        _accumulator.append(data', 0, len)
        try
          let originBlock: Block[B] = _bs.newBlock(_accumulator = recover data'.slice(len) end)?
          _originBlocks.push(originBlock)
          _getRandomBlocks()
          if not _readable then
            _readable = true
            _notifyReadable()
          end
        else
          destroy(Exception("Failed to Create Origin Block"))
          return
        end
      end
    end


  fun ref _createTuple(originBlock: Block[B], tupleParts: Array[Block[B]] iso) =>
    let tupleParts': Array[Block[B]] = consume tupleParts
    var offBlock: Block[B] = originBlock
    try
      for block in tupleParts'.values() do
        offBlock = offBlock xor? block
      end
    else
      destroy(Exception("Failed to create off block"))
      return
    end
    tupleParts'.push(offBlock)
    let currentTuple: Tuple iso = recover Tuple(_tupleSize) end
    try
      for block in tupleParts'.values() do
        currentTuple.push(block.hash)?
        _bc.put(block,{(err:(None | SectionWriteError)) (stream: WriteableOffStream[B] tag = this, block: Block[B] = block) =>
          match err
            | SectionWriteError =>
              stream.destroy(Exception("Failed to Save Tuple Block:" + try Base58.encode(block.hash.data)? else "" end))
          end
        })
      end
      _notifyData(consume currentTuple)
      if _isFinalBlock(originBlock) then
        _notifyFinished()
        _notifyComplete()
        _close()
      end
    else
      destroy(Exception("Tuple Exceeds Size"))
    end

  be _receiveRandomBlocks(block: Block[B], originBlock: Block[B], tupleParts: Array[Block[B]] iso)=>
    tupleParts.push(block)
    if tupleParts.size() >= (_tupleSize - 1) then
      _createTuple(originBlock, consume tupleParts)
      if (not _isFinalBlock(originBlock)) and (_originBlocks.size() > 0) then
        try
          _getRandomBlocks(_originBlocks.pop()?)
        end
      end
    else
      _getRandomBlocks(originBlock, consume tupleParts)
    end

  fun ref _getRandomBlocks(originBlock': (Block[B] | None) = None, tupleParts': (Array[Block[B]] iso | None) = None) =>
    let originBlock: Block[B] = match originBlock'
      | None =>
        try
          _originBlocks.pop()?
        else
          destroy(Exception("Failed to find origin block"))
          return
        end
      | let originBlock'': Block[B] =>
        originBlock''
    end
    let tupleParts: Array[Block[B]] iso =  try
      (consume tupleParts') as Array[Block[B]] iso^
    else
      recover Array[Block[B]](_tupleSize - 1) end
    end

    let dataNotify: DataNotify[Block[B]] iso = object iso is DataNotify[Block[B]]
      let originBlock: Block[B] =  originBlock
      var tupleParts: (Array[Block[B]] iso^ | None) = consume tupleParts
      let _stream: WriteableOffStream[B] tag = this
      fun ref apply(block: Block[B]) =>
        try
          _stream._receiveRandomBlocks(block, originBlock, (tupleParts = None) as Array[Block[B]] iso^ )
        else
          _stream.destroy(Exception("Failed to receive tuple blocks"))
        end
    end

    match _currentRecipe
      | let currentRecipe: BlockRecipe[B] tag =>
        currentRecipe.subscribe(consume dataNotify, true)
        currentRecipe.pull()
    end


  be read(cb: {(Tuple val)} val, size: (USize | None) = None) =>
    None

  fun ref _close() =>
    if not _destroyed() then
      _isDestroyed = true
      _notifyClose()
      let subscribers: Subscribers = _subscribers()
      subscribers.clear()
      _pipeNotifiers' = None
    end

  be close() =>
    _close()
