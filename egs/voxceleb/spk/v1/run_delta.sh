#!/usr/bin/env bash

set -e

voxceleb1_trials=data/voxceleb1_test_no_sil/trials
test_nj=8
test_use_gpu=true
stage=0


source path.sh
source parse_options.sh

echo "Running from stage $stage ..."


if [ $stage -le 0 ]; then
  # Prepare data.
  # TODO: run Kaldi script till data/train_combined_no_sil is ready.

  if [ ! -d data/train_combined_no_sil_tr ] || [ ! -d data/train_combined_no_sil_cv ]
  then
    echo "Making training and validation sets ..."
    subset_data_dir_tr_cv.py \
      --num-utt-cv 1000 \
      data/train_combined_no_sil \
      data/train_combined_no_sil_tr \
      data/train_combined_no_sil_cv
    echo "Making training and validation sets Done."
  fi
fi

if [ $stage -le 1 ]; then
  if [ ! -f exp/delta_speaker/cmvn.npy ]
  then
    echo "Computing CMVN stats ..."
    python3 -u $MAIN_ROOT/delta/main.py --cmd gen_cmvn --config conf/delta_speaker.yml
    echo "Computing CMVN stats Done."
  fi
fi

if [ $stage -le 2 ]; then
  # Train the model.
  echo "Training the model ..."
  CUDA_VISIBLE_DEVICES=0,1,2,3,4,5,6,7 \
    python3 -u $MAIN_ROOT/delta/main.py --cmd train_and_eval --config conf/delta_speaker.yml
  echo "Training the model Done."
fi

if [ $stage -le 9 ]; then
  if [ ! -d data/voxceleb1_test_no_sil ]
  then
    echo "Preparing feats for test ..."
    local/nnet3/xvector/prepare_feats_for_egs.sh \
        --compress false \
        data/voxceleb1_test data/voxceleb1_test_no_sil exp/voxceleb1_test_no_sil
    utils/fix_data_dir.sh data/voxceleb1_test_no_sil
    sed "s/\.wav//g" data/voxceleb1_test/trials > $voxceleb1_trials
    echo "Preparing feats for test done."
  fi
fi

function infer_one_set() {
  # Run inference on one data set.
  data_dir=$1
  output_dir=$2

  utils/split_data.sh $data_dir $test_nj
  mkdir -p $output_dir/split$test_nj || true
  for idx in $(seq 1 $test_nj)
  do
    mkdir $output_dir/split$test_nj/$idx || true
    sed \
      -e "s%__INFER_PATH__%$data_dir/split$test_nj/$idx%" \
      -e "s%pred_path:.*%pred_path: $output_dir/split$test_nj/$idx%" \
      conf/delta_speaker.yml > conf/delta_speaker.yml.$idx.yml
    if "$test_use_gpu"
    then
      gpu_idx=$((idx-1))
    else
      gpu_idx=
    fi
    CUDA_VISIBLE_DEVICES="$gpu_idx" \
      python3 -u $MAIN_ROOT/delta/main.py --cmd infer --config conf/delta_speaker.yml.$idx.yml &> $output_dir/split$test_nj/$idx/infer.log &
  done
  wait
  for idx in $(seq 1 $test_nj)
  do
    txt=$output_dir/split$test_nj/$idx/utt_embeddings.txt
    copy-vector ark:$txt ark,scp:$txt.ark,$txt.scp &
  done
  wait
  cat $output_dir/split$test_nj/*/utt_embeddings.txt.scp > $output_dir/utt_embeddings.txt.scp
}

infer_dir=exp/delta_speaker/ckpt/infer
test_vector_scp=$infer_dir/utt_embeddings.txt.scp
if [ $stage -le 10 ]; then
  echo "Running inference through model on test set ..."
  infer_one_set data/voxceleb1_test_no_sil $infer_dir
  echo "Running inference through model on test set done."
fi

if [ $stage -le 11 ]; then
  echo "Computing cosine scores ..."
  ivector-normalize-length scp:${test_vector_scp} ark:${test_vector_scp}.norm
  ivector-compute-dot-products <(awk '{print $1, $2}' $voxceleb1_trials) ark:${test_vector_scp}.norm ark:${test_vector_scp}.norm $infer_dir/cosine_scores
  compute-eer <(local/prepare_for_eer.py $voxceleb1_trials $infer_dir/cosine_scores) 2>&1 | tee $infer_dir/cosine_results
  echo "Computing cosine scores done."
fi

if [ $stage -le 12 ]; then
  if [ ! -d data/train_no_sil ]
  then
    echo "Preparing feats for clean training set ..."
    local/nnet3/xvector/prepare_feats_for_egs.sh \
        --compress false \
        data/train data/train_no_sil data/train_no_sil
    utils/fix_data_dir.sh data/train_no_sil
    echo "Preparing feats for clean training set done."
  fi
fi

infer_train_dir=exp/delta_speaker/ckpt/infer_train
if [ $stage -le 13 ]; then
  echo "Running inference through model on training set ..."
  infer_one_set data/train_no_sil $infer_train_dir
  echo "Running inference through model on training set done."
fi

train_vector_scp=$infer_train_dir/utt_embeddings.txt.scp
if [ $stage -le 14 ]; then
  echo "Computing PLDA ..."
  # Compute the mean vector for centering the evaluation xvectors.
  ivector-mean scp:$train_vector_scp \
    $infer_train_dir/mean.vec || exit 1;

  # This script uses LDA to decrease the dimensionality prior to PLDA.
  lda_dim=200
  ivector-compute-lda --total-covariance-factor=0.0 --dim=$lda_dim \
    "ark:ivector-subtract-global-mean scp:$train_vector_scp ark:- |" \
    ark:data/train/utt2spk $infer_train_dir/transform.mat || exit 1;

  # Train the PLDA model.
  ivector-compute-plda ark:data/train/spk2utt \
    "ark:ivector-subtract-global-mean scp:$train_vector_scp ark:- | transform-vec $infer_train_dir/transform.mat ark:- ark:- | ivector-normalize-length ark:-  ark:- |" \
    $infer_train_dir/plda || exit 1;
  echo "Computing PLDA done."
fi

if [ $stage -le 15 ]; then
  echo "PLDA scoring ..."
  ivector-plda-scoring --normalize-length=true \
    "ivector-copy-plda --smoothing=0.0 $infer_train_dir/plda - |" \
    "ark:ivector-subtract-global-mean $infer_train_dir/mean.vec scp:$test_vector_scp ark:- | transform-vec $infer_train_dir/transform.mat ark:- ark:- | ivector-normalize-length ark:- ark:- |" \
    "ark:ivector-subtract-global-mean $infer_train_dir/mean.vec scp:$test_vector_scp ark:- | transform-vec $infer_train_dir/transform.mat ark:- ark:- | ivector-normalize-length ark:- ark:- |" \
    "cat '$voxceleb1_trials' | cut -d\  --fields=1,2 |" exp/scores_voxceleb1_test || exit 1;
  echo "PLDA scoring done."
fi

if [ $stage -le 16 ]; then
  eer=`compute-eer <(local/prepare_for_eer.py $voxceleb1_trials exp/scores_voxceleb1_test) 2> /dev/null`
  mindcf1=`sid/compute_min_dcf.py --p-target 0.01 exp/scores_voxceleb1_test $voxceleb1_trials 2> /dev/null`
  mindcf2=`sid/compute_min_dcf.py --p-target 0.001 exp/scores_voxceleb1_test $voxceleb1_trials 2> /dev/null`
  echo "EER: $eer%"
  echo "minDCF(p-target=0.01): $mindcf1"
  echo "minDCF(p-target=0.001): $mindcf2"

  # TDNN model:
  # EER: 3.028%
  # minDCF(p-target=0.01): 0.3101
  # minDCF(p-target=0.001): 0.4875

  # Kaldi xvector v2:
  # EER: 3.128%
  # minDCF(p-target=0.01): 0.3258
  # minDCF(p-target=0.001): 0.5003

  # For reference, here's the ivector system from ../v1:
  # EER: 5.329%
  # minDCF(p-target=0.01): 0.4933
  # minDCF(p-target=0.001): 0.6168
fi
