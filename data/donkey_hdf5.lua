--[[
    Copyright (c) 2015-present, Facebook, Inc.
    All rights reserved.

    This source code is licensed under the BSD-style license found in the
    LICENSE file in the root directory of this source tree. An additional grant
    of patent rights can be found in the PATENTS file in the same directory.
]]--

-- Heavily moidifed by Carl to make it simpler

require 'torch'
require 'image'
require 'hdf5'
tds = require 'tds'
torch.setdefaulttensortype('torch.FloatTensor')
local class = require('pl.class')

local dataset = torch.class('dataLoader')

-- this function reads in the data files
function dataset:__init(args)
    for k,v in pairs(args) do self[k] = v end

    assert(self.labelDim > 0, "must specify labelDim (the dimension of the label vector)")
    assert(self.labelName, "must specify labelName (the variable in the labelFile to read)")
    assert(self.labelFile, "must specify labelFile (the hdf5 to load)")


    self.hdf5_data = hdf5.open(self.labelFile, 'r')
    self.permutations = torch.load('permutations.t7'):long()
    --fd:close()

    -- we are going to read args.data_list
    -- we split on the tab
    -- we use tds.Vec() because they have no memory constraint
    --self.data = tds.Vec()
    --for line in io.lines(args.data_list) do
    --  local split = {}
    --for k in string.gmatch(line, "%S+") do table.insert(split, k) end
    --self.data:insert(split[1])
    --end
    self.nImgs = self.hdf5_data:read(self.labelName):dataspaceSize()[1]

    print('found ' .. self.nImgs  .. ' items')
end

function dataset:size()
    return self.nImgs
end

-- converts a table of samples (and corresponding labels) to a clean tensor
function dataset:tableToOutput(dataTable, labelTable, extraTable)
    local data, scalarLabels, labels
    local quantity = #labelTable
    assert(dataTable[1]:dim() == 5) -- number of videos
    assert(dataTable[2]:dim() == 3) -- number of channels
    data = torch.Tensor(quantity, 5, 3, 16, self.patchSize, self.patchSize)
    scalarLabels = torch.Tensor(quantity, self.labelDim):fill(-1111)
    for i=1,#dataTable do
        data[i]:copy(dataTable[i])
        scalarLabels[i] = labelTable[i]
    end
    return data, scalarLabels, extraTable
end

-- sampler, samples with replacement from the training set.
function dataset:sample(quantity)
    assert(quantity)
    local dataTable = {}
    local labelTable = {}
    local extraTable = {}
    for i=1,quantity do
        local idx = torch.random(1, self.nImgs)
        local imgs = self.hdf5_data:read(self.labelName):partial({idx, idx},{1,5},{1,3},{1,16},{1,64},{1,64})

        local data_label = torch.random(1,120)
        local perm = self.permutations[label]	-- get the permutation
        local out = imgs:index(1,perm:long()) 	-- shuffle the clips

        table.insert(dataTable, out)
        table.insert(labelTable, data_label)
        table.insert(extraTable, idx)
    end

    return self:tableToOutput(dataTable,labelTable,extraTable)
end

-- gets data in a certain range
function dataset:get(start_idx,stop_idx)
    assert(start_idx)
    assert(stop_idx)
    assert(start_idx<stop_idx)
    assert(start_idx<=#self.data)
    local dataTable = {}
    local labelTable = {}
    local extraTable = {}

    local imgs
    if stop_idx > #self.data then
        imgs = self.hdf5_data:read(self.labelName):partial({start_idx, #self.data},{1,5},{1,3},{1,16},{1,64},{1,64})
    else
        imgs = self.hdf5_data:read(self.labelName):partial({start_idx, stop_idx},{1,5},{1,3},{1,16},{1,64},{1,64})
    end

    for idx=1,imgs:size(1) do
        local data_label = torch.random(1,120)
        local perm = self.permutations[label]	-- get the permutation
        local out = imgs[idx]:index(1,perm:long()) 	-- shuffle the clips

        table.insert(dataTable, out)
        table.insert(labelTable, data_label)
    end
    return self:tableToOutput(dataTable,labelTable,extraTable)
end

-- function to load the image, jitter it appropriately (random crops etc.)
function dataset:trainHook(img)
    collectgarbage()
    local input = self:loadImage(img)
    local iW = input:size(3)
    local iH = input:size(2)
    local nC = input:size(1)

    -- do random crop
    local oW = self.fineSize
    local oH = self.fineSize
    local h1
    local w1
    if self.cropping == 'random' then
        h1 = math.ceil(torch.uniform(1e-2, iH-oH))
        w1 = math.ceil(torch.uniform(1e-2, iW-oW))
    elseif self.cropping == 'center' then
        h1 = math.ceil((iH-oH)/2)
        w1 = math.ceil((iW-oW)/2)
    else
        assert(false, 'unknown mode ' .. self.cropping)
    end
    local out = image.crop(input, w1, h1, w1 + oW, h1 + oH)
    assert(out:size(2) == oW)
    assert(out:size(3) == oH)
    -- do hflip with probability 0.5
    if torch.uniform() > 0.5 then out = image.hflip(out); end
    out:mul(2):add(-1) -- make it [0, 1] -> [-1, 1]

    -- subtract mean
    for c=1,nC do
        out[{ c, {}, {} }]:add(-self.mean[c])
    end

    return self:generatePuzzle(out)
end

-- reads an image disk
-- if it fails to read the image, it will use a blank image
-- and write to stdout about the failure
-- this means the program will not crash if there is an occassional bad apple
function dataset:loadImage(input)

    local iW = input:size(4)
    local iH = input:size(3)
    if iW < iH then
        input = image.scale(input[1], opt.loadSize, opt.loadSize * iH / iW)
    else
        input = image.scale(input[1], opt.loadSize * iW / iH, opt.loadSize)
    end

    return input
end

-- data.lua expects a variable called trainLoader
trainLoader = dataLoader(opt)
