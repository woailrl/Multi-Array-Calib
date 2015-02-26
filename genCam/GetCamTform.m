function [T_Ckm1_Ck, T_Cov_Ckm1_Ck, matches, points, pointsOut] = GetCamTform( image, imageOld, pOld, mask, K, maxPoints )
%GENCAM Gets normalized camera transform given two images and K
%--------------------------------------------------------------------------
%   Required Inputs:
%--------------------------------------------------------------------------
%   image- n by m image
%   fOld- features in previous image ([] if there is no previous image)
%   pOld- points in previous image ([] if there is no previous image)
%   mask- n by m logical matrix. If zero points at this location will not
%   be used( allows removal of parts of vechile in view)
%   K- camera matrix
%
%--------------------------------------------------------------------------
%   Outputs:
%--------------------------------------------------------------------------
%   T_Ckm1_Ck - normalized camera transform from previous image to image
%   matches- matches between previous points matches(:,1) and new points
%   matches(:,2)
%   fNew- features in current image
%   pNew- points in current image
%
%--------------------------------------------------------------------------
%   References:
%--------------------------------------------------------------------------
%   This function is part of the Multi-Array-Calib toolbox 
%   https://github.com/ZacharyTaylor/Multi-Array-Calib
%   
%   This code was written by Zachary Taylor
%   zacharyjeremytaylor@gmail.com
%   http://www.zjtaylor.com

%detect features in images
pNew = detectMinEigenFeatures(imageOld);
pNew = pNew.Location;

%mask points
notMasked = mask(round(pNew(:,2))+size(mask,1)*(round(pNew(:,1))-1)) ~= 0;
pNew = pNew(notMasked,:);

points = [pOld;pNew];

pointTracker = vision.PointTracker('MaxBidirectionalError', 2);
initialize(pointTracker, points, imageOld);
[pointsOut, matches] = step(pointTracker, image);
release(pointTracker);

points = points(matches,:);
pointsOut = pointsOut(matches,:);

pointsVar = EstPointVar( image, pointsOut );

[T_Ckm1_Ck, T_Cov_Ckm1_Ck, ~, inliers] = getTandPoints(pointsOut,points,K);

matches(matches)  = inliers;
matches = matches(1:size(pOld,1));
points = points(inliers,:);
pointsOut = pointsOut(inliers,:);

if(size(points,1) > maxPoints)
    points = points(1:maxPoints,:);
    pointsOut = pointsOut(1:maxPoints,:);
end

end

function [T_Ckm1_Ck, T_Cov_Ckm1_Ck, points, inliers] = getTandPoints(mNew,mOld,K)

    %get fundemental matrix
    [F, inliers] = estimateFundamentalMatrix(mOld,mNew,'NumTrials',500,'DistanceThreshold',0.001);
    mOld = mOld(inliers,:);
    mNew = mNew(inliers,:);
    
    %get essential matrix
    E = K(1:3,1:3)'*F*K(1:3,1:3);

    %Hartley matrices
    W = [0 -1 0; 1 0 0; 0 0 1];
       
    %get P
    [U,~,V] = svd(E);
    RA = U*W*V';
    RB = U*W'*V';
    
    RA = RA*sign(RA(1,1));
    RB = RB*sign(RB(1,1));
    
    TA = U(:,3);
    TB = -U(:,3);
    
    %get Transform
    T_Ckm1_Ck = zeros(4,4,4);
    
    T_Ckm1_Ck(:,:,1) = [[RA,TA];[0,0,0,1]];
    T_Ckm1_Ck(:,:,2) = [[RA,TB];[0,0,0,1]];
    T_Ckm1_Ck(:,:,3) = [[RB,TA];[0,0,0,1]];
    T_Ckm1_Ck(:,:,4) = [[RB,TB];[0,0,0,1]];
        
    best = zeros(4,1);
 
    %match points
    points = zeros(size(mNew,1),6,4);
    for j = 1:4
        T_Ckm1_Ck(:,:,j) = T_Ckm1_Ck(:,:,j);
        points(:,:,j) = getPoints(mNew,mOld,T_Ckm1_Ck(:,:,j),K);
        best(j,1) = median(points(:,3,j)) + median(points(:,6,j));
    end
    
    [~,idx] = max(best);
    points = points(:,:,idx);
    T_Ckm1_Ck = T_Ckm1_Ck(:,:,idx);
    
    %sample data
    T_Cov_Ckm1_Ck = zeros(100,6);
    for i = 1:100
        %get sampled points
        [mOBS,idx] = datasample(mOld,size(mOld,1));
        mNBS = mNew(idx,:);
        
        %find fundemental matrix (using fundmatrix for speed)
        F = Fundmatrix([mOBS,ones(size(mOBS,1),1)]',[mNBS,ones(size(mOBS,1),1)]');
        
        %add random error to focal length and centre point
        Kr = K + [randn(1),0,randn(1),0;0,randn(1),randn(1),0;0,0,0,0];
        
        %get essential matrix
        E = Kr(1:3,1:3)'*F*Kr(1:3,1:3);
       
        %get P
        [U,~,V] = svd(E);
        RA = U*W*V';
        RB = U*W'*V';

        if (sum(U(:,3)) > 0)
            T = U(:,3);
        else
           T = -U(:,3);
        end
        
        RA = repmat(sign(diag(RA)),1,3).*RA;
        RB = repmat(sign(diag(RB)),1,3).*RB;
        
        eA = RA - T_Ckm1_Ck(1:3,1:3); eA = sum(eA(:).^2);
        eB = RB - T_Ckm1_Ck(1:3,1:3); eB = sum(eB(:).^2);
        
        if (eB > eA)
            T_Cov_Ckm1_Ck(i,:) = T2V([RA,T;[0,0,0,1]]);
        else
            T_Cov_Ckm1_Ck(i,:) = T2V([RB,T;[0,0,0,1]]);
        end
    end
    T_Cov_Ckm1_Ck = var(T_Cov_Ckm1_Ck);
    
    %filter out negitive and distant point matches
    badPoints = or(sqrt(sum(points.^2,2)) > 1000, points(:,3) < 0);
    inliers(badPoints) = 0;
    
    T_Ckm1_Ck = T2V(T_Ckm1_Ck);
end

function [points] = getPoints(mNew,mOld,T,K)
    
    %match points
    points = zeros(size(mNew,1),6);
    
    P1 = K;
    P2 = K*T;
    for i = 1:size(mNew,1)

        A = zeros(4,4);
        A(1,:) = mOld(i,1)*P1(3,:)' - P1(1,:)';
        A(2,:) = mOld(i,2)*P1(3,:)' - P1(2,:)';
        A(3,:) = mNew(i,1)*P2(3,:)' - P2(1,:)';
        A(4,:) = mNew(i,2)*P2(3,:)' - P2(2,:)';

        [~, ~, V] = svd(A);
        points(i,1:3) = V(1:3,4)'/V(4,4);
        temp = T*[points(i,1:3),1]';
        points(i,4:6) = temp(1:3);
    end
end

