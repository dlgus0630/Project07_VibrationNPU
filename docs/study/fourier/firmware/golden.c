// ============================================================================
// [공부용 주석 사본] fourier/firmware/golden.c
// 실제 커밋되는 원본에는 이런 상세 주석이 없습니다. 이 파일은 학습 전용입니다.
// ============================================================================
//
// 이 파일이 하는 일 한 줄 요약: fft64_features.v + npu_2pe.v가 하드웨어로
// 하는 계산과 **완전히 똑같은 계산**을 순수 C로 다시 구현합니다(정수 연산만
// 사용, 부동소수점 없음). 왜 "golden model"이 필요한지는 golden.h의 설명을
// 먼저 보세요.
//
// 왜 하드웨어와 "똑같이" 정수 연산만 쓰는가?
// -----------------------------------------------------------------------
// 만약 이 C 코드가 `float`나 `double`을 썼다면, FPGA의 정수/고정소수점
// 계산과 반올림 방식이 미묘하게 달라서 결과가 살짝 어긋날 수 있습니다.
// 그러면 "하드웨어가 틀렸다"와 "그냥 반올림 오차다"를 구분하기 어려워져서
// 검증의 의미가 퇴색됩니다. 그래서 이 코드는 FFT의 모든 곱셈·시프트·
// 나눗셈까지 하드웨어와 똑같은 정수 연산으로 재현합니다 — `floor_shift()`
// 함수가 핵심입니다.
//
// `floor_shift(v, shift)`가 하는 일
// -----------------------------------------------------------------------
// "v를 2^shift로 나누되, 항상 내림(floor, 더 작은 쪽 정수로) 방향으로
// 반올림한다"는 뜻입니다. 이게 중요한 이유: Verilog의 `>>>`(산술 우측
// 시프트)는 음수에 대해서도 "항상 -무한대 방향으로 버림"하는 동작을
// 합니다(예: -3 >>> 1 = -2, 0을 향해 버리는 게 아니라 더 작은 쪽으로).
// C의 정수 나눗셈(`/`)은 반대로 "0을 향해 버림"합니다(예: -3/2 = -1,
// 더 큰 쪽으로). 이 차이를 그냥 두면 음수 값이 있을 때마다 결과가
// 어긋나므로, `floor_shift()`가 명시적으로 "음수면 (-v+d-1)/d에 음수를
// 붙여서" -무한대 방향 버림을 흉내 냅니다. 파일 맨 위 주석의
// "All negative divisions round toward -infinity"라는 말이 바로 이
// 문제를 가리킵니다(참고로 pid_fixed.v에서도 이 같은 이슈가 언급됩니다).
//
// 비트 반전(bit-reversal)
// -----------------------------------------------------------------------
// `for(n=0;n<64;n++){ ... reverse=(reverse<<1)|(v&1); v>>=1; }`가
// fft64_features.v의 `reverse6()` 함수와 정확히 같은 일을 합니다 — 6비트
// 인덱스의 비트 순서를 뒤집어서, DIT FFT가 요구하는 입력 순서로 샘플을
// 재배치합니다.
//
// FFT 나비 연산 이중 루프
// -----------------------------------------------------------------------
// `for(s=1;s<=6;s++)` (6단계) 안에 `for(base=0;base<64;base+=span)`
// (그룹별로)과 `for(j=0;j<half;j++)`(그룹 안의 각 나비 연산)이 중첩된
// 구조가, fft64_features.v의 상태 기계(stage/base/j가 하드웨어에서는
// 레지스터로, 여기선 그냥 C의 for 루프 변수로)와 정확히 같은 계산 순서를
// 만듭니다. `t=j*64/span`이 twiddle factor 인덱스인데, 하드웨어에서는
// `ti=j<<(6-stage)`로 계산했던 것과 수학적으로 동일합니다(시프트 대신
// 나눗셈으로 표현했을 뿐).
//
// FFT 결과를 저장한 뒤, 4개 대역 특징을 뽑는 부분(sums, band)도
// fft64_features.v의 FACC 상태와 완전히 같은 계산(맨해튼 거리 근사,
// 4구간 분류)입니다.
//
// 신경망 순전파(forward pass) 부분
// -----------------------------------------------------------------------
// `for(n=0;n<4;n++){ acc=b1[n]; for(j=0;j<4;j++)acc+=features[j]*w1[n][j];
// hidden[n]=clamp(floor_shift(acc,SHIFT1),0,127); }`가 은닉층 계산이고
// (ReLU는 `clamp(...,0,127)`의 하한이 0이라는 것으로 표현됨), 그다음
// 블록이 출력층 계산입니다(하한이 -128이라 ReLU 없음, npu_2pe.v의
// `quant()` 함수에서 `relu` 인자가 group_id==2일 때 0이었던 것과 대응).
// `w1[n][j]`, `b1[n]` 등은 model_data.h에 미리 정의된 가중치/편향
// 상수들로, npu_2pe.v가 `.mem` 파일에서 읽어오는 것과 **같은 숫자값**을
// C 헤더 상수로도 갖고 있는 것입니다(두 곳에 값이 중복 저장되어 있는
// 셈인데, 학습 스크립트가 두 형식을 동시에 생성해서 항상 일치하도록
// 관리합니다).
// ============================================================================

// Portable independent C reference, shared by host verification and Zynq ARM.
#include "golden.h"
#include "model_data.h"

// v를 2^shift로 나누되 항상 -무한대 방향으로 내림(floor). Verilog `>>>`와 동일한 반올림 규칙.
static int32_t floor_shift(int64_t v,unsigned shift) {
    int64_t d=(int64_t)1<<shift;
    return (int32_t)(v>=0?v/d:-((-v+d-1)/d));
}
// low~high 범위를 벗어나면 경계값으로 자르는 포화(saturate) 함수 — ReLU도 이걸로 표현(low=0).
static int32_t clamp(int32_t v,int32_t low,int32_t high) { return v<low?low:v>high?high:v; }

void infer_integer(const int16_t samples[64],inference_result *r) {
    unsigned n,s,j,base,k;

    // --- 1단계: bit-reversal로 입력 재배치 (fft64_features.v의 reverse6()과 동일) ---
    for(n=0;n<64;n++) {
        unsigned reverse=0,v=n;
        for(j=0;j<6;j++){reverse=(reverse<<1)|(v&1);v>>=1;}
        r->re[reverse]=samples[n];r->im[reverse]=0; // 원래 신호는 실수이므로 허수부는 0
    }

    // --- 2단계: 6단계 라딕스-2 FFT (fft64_features.v의 READ/MULT/WRITE 상태와 동일한 계산) ---
    for(s=1;s<=6;s++) {
        unsigned span=1U<<s,half=span/2;
        for(base=0;base<64;base+=span)for(j=0;j<half;j++) {
            unsigned a=base+j,b=a+half,t=j*64/span; // twiddle factor 인덱스
            int32_t ar=r->re[a],ai=r->im[a];
            // 복소수 곱셈 b*w (하드웨어의 real_product/imag_product와 동일한 전개식)
            int32_t tr=floor_shift((int64_t)r->re[b]*tw_re[t]-(int64_t)r->im[b]*tw_im[t],15);
            int32_t ti=floor_shift((int64_t)r->re[b]*tw_im[t]+(int64_t)r->im[b]*tw_re[t],15);
            // 나비 연산: 새 a=(a+t)/2, 새 b=(a-t)/2 (하드웨어의 sat16_half와 같은 /2 + 포화)
            r->re[a]=(int16_t)clamp(floor_shift(ar+tr,1),-32768,32767);
            r->im[a]=(int16_t)clamp(floor_shift(ai+ti,1),-32768,32767);
            r->re[b]=(int16_t)clamp(floor_shift(ar-tr,1),-32768,32767);
            r->im[b]=(int16_t)clamp(floor_shift(ai-ti,1),-32768,32767);
        }
    }

    // --- 3단계: FFT 결과에서 4개 주파수 대역 특징 추출(맨해튼 거리 근사 + 대역 분류) ---
    for(n=0;n<4;n++)r->features[n]=0;
    {uint32_t sums[4]={0,0,0,0};
        for(k=1;k<32;k++) {
            unsigned band=k<=6?0:k<=12?1:k<=20?2:3; // fft64_features.v의 band 계산과 동일
            int32_t re=r->re[k],im=r->im[k];
            sums[band]+=(uint32_t)((re<0?-re:re)+(im<0?-im:im)); // |실수부|+|허수부|
        }
        for(n=0;n<4;n++)r->features[n]=(uint8_t)clamp((int32_t)(sums[n]>>5),0,127);
    }

    // --- 4단계: 은닉층(4개 뉴런, ReLU 적용) ---
    for(n=0;n<4;n++) {
        int64_t acc=b1[n];for(j=0;j<4;j++)acc+=(int32_t)r->features[j]*w1[n][j];
        r->hidden[n]=(uint8_t)clamp(floor_shift(acc,SHIFT1),0,127); // 하한 0 = ReLU
    }

    // --- 5단계: 출력층(2개 뉴런, ReLU 없음 — 최종 점수는 음수도 의미 있음) ---
    for(n=0;n<2;n++) {
        int64_t acc=b2[n];for(j=0;j<4;j++)acc+=(int32_t)r->hidden[j]*w2[n][j];
        r->logits[n]=(int8_t)clamp(floor_shift(acc,SHIFT2),-128,127);
    }

    // --- 6단계: 최종 판정 — 두 점수 중 "이상" 점수가 더 크면 1 ---
    r->class_id=(uint8_t)(r->logits[1]>r->logits[0]);
}
