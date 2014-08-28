require 'paths'
require('nn')
require('pl')
require('torch')
require(codeFolder.. 'rbm-util')
require(codeFolder.. 'rbm-regularization')
require(codeFolder..'rbm-grads')
--require ('socket')  -- for timing 

datafolder = '../../sigp/dataanalysis/'
 trainFiles = {'dataanalysis/Eukar1.dat','dataanalysis/Eukar2.dat','dataanalysis/Eukar3.dat'}
 valFiles = {'dataanalysis/Eukar4.dat'}

function rbmtrain(rbm,train,val,semisup)
     local x_train,y_train,x_val,y_val,x_semisup
     x_train = train.data

     y_train = OneOfK(train)
     if val then
        x_val   = val.data
        y_val   = OneOfK(val)
     end
     if semisup then
        x_semisup = semisup.data
     end


     -- train RBM
     local x_tr,y_tr,x_semi, total_time, epoch_time,acc_train, best_val_err,patience, best_rbm,best
     printrbm(rbm,x_train,x_val,x_semisup)

     patience = rbm.patience
     total_time  = os.time()

     -- extend error tensors if resuming training
     if rbm.err_train:size(1) < rbm.numepochs then
          best_val_err = rbm.err_val[rbm.currentepoch]
          rbm.err_recon_train = extendTensor(rbm, rbm.err_recon_train,rbm.numepochs)
          rbm.err_train = extendTensor(rbm,rbm.err_train,rbm.numepochs)
          rbm.err_val = extendTensor(rbm,rbm.err_val,rbm.numepochs) 
          best_rbm = cprbm(rbm)  
     end

     best_val_err = best_val_err or 1/0
     print("Best Val err",best_val_err)
     for epoch = rbm.currentepoch, rbm.numepochs do 
          epoch_time = os.time()
          rbm.cur_err = torch.zeros(1)
          rbm.currentepoch = epoch
          
          for i = 1, x_train:size(1) do  -- iter over samples
               x_tr,y_tr,x_semi = getsamples(rbm,x_train,y_train,x_semisup,i)
               regularization.dropout(rbm)                          -- create dropout mask for hidden units
               grads.calculategrads(rbm,x_tr,y_tr,x_semi)           -- calculates dW, dU, db, dc and dd
               regularization.applyregularization(rbm)              -- regularizes dW, dU, db, dc and dd
               updategradsandmomentum(rbm) 
                
               -- update vW, vU, vb, vc and vd, formulae: vx = vX*mom + dX                    
               updateweights(rbm)                                   -- updates W,U,b,c and d, formulae: X =  X + vX
               
               if (i %  5000) == 0 then                              -- indicate progress
                    io.write(".") 
                    io.flush()
               end
               
               -- Force garbagecollector to collect
               if (i % 20) == 0 then
                    collectgarbage()
               end

          end  -- end samples loop          
          epoch_time = os.time() - epoch_time 

          -- calc. train recon err and train pred error
          rbm.err_recon_train[epoch]    = rbm.cur_err:div(rbm.n_samples)
          rbm.err_train[epoch]          = rbm.errorfunction(rbm,x_train,y_train)
          
          if x_val and y_val then
               -- Eearly Stopping
               rbm.err_val[epoch] = rbm.errorfunction(rbm,x_val,y_val)
               if rbm.err_val[epoch] < best_val_err then
                    best_val_err = rbm.err_val[epoch]
                    patience = rbm.patience
                    saverbm(rbm.tempfile,rbm) -- save current best
                    best_rbm = cprbm(rbm)     -- save best weights
                    best = '***'
                    lastdecay = rbm.lrdecay
               else
                    patience = patience - 1 
                    best = ''

                    -- DECAY laarning rate
                    if rbm.lrdecay ~= 0 then
                        lastdecay = lastdecay or rbm.lrdecay  -- init decay
                        lastdecay = lastdecay - 1

                        if lastdecay == 0 then
                            lastdecay = rbm.lrdecay
                            rbm.learningrate = rbm.learningrate / 2
                            print("Decay learning rate")
                        end
                    end 
               end
          end         
          displayprogress(rbm,epoch,epoch_time,patience,best or '')
          
          if patience < 0 then  -- Stop training
               -- Cp weights from best_rbm
               rbm.W = best_rbm.W:clone()
               rbm.U = best_rbm.U:clone()
               rbm.b = best_rbm.b:clone()
               rbm.c = best_rbm.c:clone()
               rbm.d = best_rbm.d:clone()
               break
          end
          
     end  -- end epoch loop
     total_time = os.time() - total_time 
     print("Mean epoch time:", total_time / rbm.numepochs)
     return(rbm)
end

function displayprogress(rbm,epoch,epoch_time,patience,best)
     local strepoch, lrmom, err_recon, err_train, err_val, epoch_time_patience
     
     strepoch   = string.format("%i/%i | ",epoch,rbm.numepochs)
     lrmom = string.format("LR: %f MOM %f | ",rbm.learningrate,rbm.momentum)
     err_recon  = string.format("ERROR: Recon %4.1f ",rbm.err_recon_train[epoch])
     err_train     = string.format("TR: %f ", rbm.err_train[epoch] )
     err_val       = string.format("VAL: %f |", rbm.err_val[epoch] )
     epoch_time_patience = string.format("time: %4.0f Patience %i",epoch_time,patience)
     
     outstr = strepoch .. lrmom .. err_recon .. err_train .. err_val .. epoch_time_patience .. best
     print(outstr)
  
end

function getsamples(rbm,x_train,y_train,x_semisup,i_tr)
     local x_tr, y_tr,i_semi,x_semi
     
     -- Fetch X values. Choose if X should be sampled or not
     -- Sampling mostly usefull for stacked RBM's
     x_tr = x_train[i_tr]:resize(1, rbm.n_visible)
     if rbm.samplex then
          x_tr = sampler(x_tr,rbm.rand)
     end

     
     if rbm.toprbm == 1 then
        -- For TOP RBM we need to fetch the class labels
        y_tr = y_train[i_tr]:resize(1, rbm.n_classes )
     else
        -- for non top rbm's we just clamp Y to zero which is the same 
        -- as training p(x)
        y_tr = torch.zeros(1,rbm.n_classes)
     end

     if rbm.beta > 0 then  -- return semisupervised samples aswell
           i_semi = (i_tr-1) % x_semisup:size(1) +1;
           x_semi = x_semisup[i_tr]:resize(1,rbm.n_visible)
     end
     
     return x_tr,y_tr,x_semi
end

function updategradsandmomentum(rbm)
      -- multiply updates by learningrate
      rbm.dW:mul(rbm.learningrate)
      rbm.dU:mul(rbm.learningrate)
      rbm.db:mul(rbm.learningrate)
      rbm.dc:mul(rbm.learningrate)
      rbm.dd:mul(rbm.learningrate)
      
      -- If momentum is zero this will be zero
      --if momentum > 0 then
      
      
     if rbm.momentum > 0 then  
          rbm.vW:mul(rbm.momentum)
          rbm.vU:mul(rbm.momentum)
          rbm.vb:mul(rbm.momentum)
          rbm.vc:mul(rbm.momentum)
          rbm.vd:mul(rbm.momentum)
     else
          rbm.vW:fill(0)
          rbm.vU:fill(0)
          rbm.vb:fill(0)
          rbm.vc:fill(0)
          rbm.vd:fill(0) 
     end
     
      -- Add current update to momentum
      rbm.vW:add(rbm.dW)
      rbm.vU:add(rbm.dU)
      rbm.vb:add(rbm.db)
      rbm.vc:add(rbm.dc)
      rbm.vd:add(rbm.dd)
end

function updateweights(rbm)
      -- update gradients
      rbm.W:add(rbm.vW)
      rbm.U:add(rbm.vU)
      rbm.b:add(rbm.vb)
      rbm.c:add(rbm.vc)
      rbm.d:add(rbm.vd)
end


function cprbm(rbm)
     newrbm = {}
     newrbm.W = rbm.W:clone()
     newrbm.U = rbm.U:clone()
	newrbm.b = rbm.b:clone()
	newrbm.c = rbm.c:clone()
	newrbm.d = rbm.d:clone()
     return(newrbm)
end

-- extend old tensor to 
function extendTensor(rbm,oldtensor,newsize,fill)
     if fill then fill = fill else fill = -1 end
     local newtensor
     newtensor = torch.Tensor(newsize):fill(fill)
     newtensor[{{1,rbm.currentepoch}}] = oldtensor[{{1,rbm.currentepoch}}]:clone()
     return newtensor
end