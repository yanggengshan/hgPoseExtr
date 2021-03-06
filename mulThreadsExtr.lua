--[[
 - Filename:        mod_mulThreadsExtr.lua
 - Date:            Jul 25 2016
 - Last Edited by:  Gengshan Yang
 - Description:     Main file for extracting pose features for a list of
 -                  perison detection results
 --]]

--[[ Parse arguments 
  ]]--
cmd = torch.CmdLine()
cmd:text()
cmd:text('Extracting pose features from objection detection results')
cmd:text()
cmd:text('Options')
cmd:option('-initpos', 1, 'initial sample pointer from 1 to 2.8m')
cmd:option('-batchsize', 5, 'number of samples in a batch, ~3G memory for 5')
cmd:option('-iter', 100, 'number of batches to run')
cmd:option('-outname', 'default', 'name of the outpuf file')
cmd:option('-gpunum', 1, 'number of GPU device to use')
cmd:option('-gpuoffset', 0, 'to control the offset of GPU device index')
cmd:text()
local args = cmd:parse(arg)  -- mark local to pass into threads

--[[ Initialization
  ]]--
local threads = require 'threads'
-- 'shared serialize' to change global values
threads.Threads.serialization('threads.sharedserialize')
local currPointer = torch.IntTensor(1): -- point to current data
                    fill(args['initpos'])  -- tensor is sharable
local lap = torch.FloatTensor(10):fill(0)  -- to record the time lapse

local pool = threads.Threads(
    args['gpunum'],
    function(threadid)
        print('starting a new thread# ' .. threadid)
        -- necessary dl modules --
        require 'nn'
        require 'nngraph'
        require 'cunn'
        require 'cudnn'
        require 'cutorch'

        -- for extracting pose features --
        require 'mulThreadsExtrUtil'
        require 'hdf5'

        -- paths --
        batchSize = args['batchsize']
        print('batchSize=' .. batchSize)
        modelPath = 'umich-stacked-hourglass.t7'
        inputFilePath = '/home/gengshan/workJul/darknet/results/'..
                        'comp4_det_test_person.txt'
        outputFilePath = '/data/gengshan/pose/' ..
                         args['outname'] .. threadid ..'.h5'
        print('outfile=' .. outputFilePath)
    end,
    function(threadid)
        -- get data
        detList = readDectionList(inputFilePath, {args['initpos'],
                                 args['batchsize'] * args['iter']}, false)
        -- open output file
        os.execute('rm ' .. outputFilePath)
        outFile = hdf5.open(outputFilePath, 'a')
 
        -- init models
        cutorch.setDevice(threadid + args['gpuoffset'])
        print('dev=' .. threadid + args['gpuoffset'])
        m = torch.load(modelPath)
        
        -- init input buffer
        centerList = {}
        scaleList = {}
        imgList = {}
        inpGPU = torch.CudaTensor():resize(batchSize, 3, 256, 256)
        inpCPU = torch.FloatTensor():resize(batchSize, 3, 256, 256)
        
        -- init output buffer
        outGPU = torch.CudaTensor():resize(batchSize, 16, 64, 64)
        hmCPU = torch.FloatTensor():resize(batchSize, 16, 64, 64)
        preds_hm = {}
        preds_img = {}

        -- other vars visible to thread, to avoid garbage
        currPointerLoc = 1
        begLoc = args['initpos']  -- to recover indexing for getBatch()
        timer1 = torch.Timer()  -- for timing in this file
        timer2 = torch.Timer()  -- for timing in Util file
        locLap = torch.FloatTensor(10)  -- syncronize with global lap
        detRes = {}  -- to store detection results
        it_mod = 0  -- number in getBatch for counting
    end
)

collectgarbage()
collectgarbage()
local jobdone = 0
local beg = tonumber(os.date"%s")
print('jobs= ' .. args['iter'])
for it = 1, args['iter'] do
    pool:addjob(
        function()
            currPointerLoc = currPointer[1]  -- so that funcs in another file can see
            currPointer:add(batchSize)
            print('thread ' .. __threadid .. '. currPointer ' .. currPointerLoc ..
                  ' time ' .. tonumber(os.date"%s") - beg .. 's')
            locLap:fill(0)

            -- Get a batch of eval data --
            timer1:reset()
            getBatch(batchSize)
            locLap[1] = locLap[1] + timer1:time().real

            -- Get pose estimation --
            timer1:reset()
            getPred(batchSize)
            locLap[2] = locLap[2] + timer1:time().real

            -- Dump results to .h5 file -- 
            dumpResult(batchSize)

            -- collect garbage --
            timer1:reset()
            if it % 100 then
                collectgarbage()
                collectgarbage()
            end
            locLap[10] = locLap[10] + timer1:time().real
            lap:add(locLap)
            return __threadid  -- global var auto-stored when creating threads
        end,

        function(id)
            -- print(string.format("task %d finished (ran on thread ID %x)", i, id))
            jobdone = jobdone + 1
        end
    )
end


pool:specific(true)
for it = 1, args['gpunum'] do
    pool:addjob(
        it,
        function()
            outFile:close()
            print('h5_' .. it .. ' closed.')
        end
    )
end

pool:synchronize()

print(string.format("%d jobs done", jobdone))

print('main model:')
print(lap[{{1, 2}}])
print('submodels of model 1:')
print(lap[{{3, 4}}])
print('submodels of model 2:')
print(lap[{{5, 9}}])

collectgarbage()
collectgarbage()

pool:terminate()
