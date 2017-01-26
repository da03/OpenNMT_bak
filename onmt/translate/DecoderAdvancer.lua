--[[ DecoderAdvancer is an implementation of Advancer for how to advance one
  step in decoder.
--]]
local DecoderAdvancer = torch.class('DecoderAdvancer', 'Advancer')

--[[ Constructor.

Parameters:

  * `decoder` - an `onmt.Decoder` object.
  * `batch` - an `onmt.data.Batch` object.
  * `decStates` - initial decoder states.
  * `context` - encoder output (batch x n x rnnSize).
  * `opt` - options containing `max_sent_length` and `max_num_unks`.
  * `dicts` - optional, dictionary for additional features.

--]]
function DecoderAdvancer:__init(decoder, batch, decStates, context, opt, dicts)
  self.decoder = decoder
  self.batch = batch
  self.decStates = decStates
  self.context = context
  self.opt = opt
  self.dicts = dicts
end

--[[Returns an initial beam.

Returns:

  * `beam` - an `onmt.translate.Beam` object.

--]]
function DecoderAdvancer:initBeam()
  local tokens = onmt.utils.Cuda.convert(torch.IntTensor(self.batch.size))
    :fill(onmt.Constants.BOS)
  local features = {}
  if self.dicts then
    for j = 1, #self.dicts.tgt.features do
      features[j] = torch.IntTensor(self.batch.size):fill(onmt.Constants.EOS)
    end
  end
  local sourceSizes = onmt.utils.Cuda.convert(self.batch.sourceSize)

  -- Define state to be { decoder states, decoder output, context,
  -- attentions, features, sourceSizes, step }.
  local state = {self.decStates, nil, self.context, nil, features,
    sourceSizes, 1}
  return onmt.translate.Beam.new(tokens, state)
end

--[[Updates beam states given new tokens.

Parameters:

  * `beam` - beam with updated token list.

]]
function DecoderAdvancer:update(beam)
  local state = beam:state()
  local decStates, decOut, context, _, features, sourceSizes, t
      = table.unpack(state, 1, 7)
  local tokens = beam:tokens()
  local token = tokens[#tokens]
  local inputs
  if #features == 0 then
    inputs = token
  elseif #features == 1 then
    inputs = { token, features[1] }
  else
    inputs = { token }
    table.insert(inputs, features)
  end
  self.decoder:maskPadding(sourceSizes, self.batch.sourceLength)
  decOut, decStates = self.decoder
                      :forwardOne(inputs, decStates, context, decOut)
  t = t + 1
  local softmaxOut = self.decoder.softmaxAttn.output
  local nextState = {decStates, decOut, context, softmaxOut, nil,
    sourceSizes, t}
  beam:setState(nextState)
end

--[[Expand function. Expands beam by all possible tokens and returns the
  scores.

Parameters:

  * `beam` - an `onmt.translate.Beam` object.

Returns:

  * `scores` - a 2D tensor of size `(batchSize, numTokens)`.

]]
function DecoderAdvancer:expand(beam)
  local state = beam:state()
  local decOut = state[2]
  local out = self.decoder.generator:forward(decOut)
  local features = {}
  for j = 2, #out do
    local _, best = out[j]:max(2)
    features[j - 1] = best:view(-1)
  end
  state[5] = features
  local scores = out[1]
  return scores
end

--[[Checks which hypotheses in the beam are already finished. A hypothesis is
  complete if i) an onmt.Constants.EOS is encountered, or ii) the length of the
  sequence is greater than or equal to `opt.max_sent_length`.

Parameters:

  * `beam` - an `onmt.translate.Beam` object.

Returns: a binary flat tensor of size `(batchSize)`, indicating which hypotheses are finished.

]]
function DecoderAdvancer:isComplete(beam)
  local tokens = beam:tokens()
  local seqLength = #tokens - 1
  local complete = tokens[#tokens]:eq(onmt.Constants.EOS)
  if seqLength > self.opt.max_sent_length then
    complete:fill(1)
  end
  return complete
end

--[[Checks which hypotheses in the beam shall be pruned. We disallow empty
 predictions, as well as predictions with more UNKs than `opt.max_num_unks`.

Parameters:

  * `beam` - an `onmt.translate.Beam` object.

Returns: a binary flat tensor of size `(batchSize)`, indicating which beams shall be pruned.

]]
function DecoderAdvancer:filter(beam)
  local tokens = beam:tokens()
  local numUnks = onmt.utils.Cuda.convert(torch.zeros(tokens[1]:size(1)))
  for t = 1, #tokens do
    local token = tokens[t]
    numUnks:add(onmt.utils.Cuda.convert(token:eq(onmt.Constants.UNK):double()))
  end
  -- Disallow too many UNKs
  local unSatisfied = numUnks:gt(self.opt.max_num_unks)
  -- Disallow empty hypotheses
  if #tokens == 2 then
    unSatisfied:add(tokens[2]:eq(onmt.Constants.EOS))
  end
  return unSatisfied:ge(1)
end

return DecoderAdvancer
