// STREAM-style memory bandwidth: read-only sum and copy over 1 GiB arrays, OpenMP, best of 5.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <omp.h>
#define N (1UL<<27)   /* 128 Mi doubles = 1 GiB per array */
int main(void){
  double *a=aligned_alloc(64,N*8), *b=aligned_alloc(64,N*8);
  #pragma omp parallel for
  for(size_t i=0;i<N;i++){a[i]=1.0;b[i]=2.0;}
  double best_read=0,best_copy=0;
  for(int r=0;r<5;r++){
    double t=omp_get_wtime(), s=0;
    #pragma omp parallel for reduction(+:s)
    for(size_t i=0;i<N;i++) s+=a[i];
    t=omp_get_wtime()-t; double gb=N*8/1e9/t; if(gb>best_read)best_read=gb; if(s<0)puts("x");
    t=omp_get_wtime();
    #pragma omp parallel for
    for(size_t i=0;i<N;i++) b[i]=a[i];
    t=omp_get_wtime()-t; gb=2*N*8/1e9/t; if(gb>best_copy)best_copy=gb;
  }
  printf("threads=%d read=%.1f GB/s copy(read+write)=%.1f GB/s\n",omp_get_max_threads(),best_read,best_copy);
  return 0;
}
