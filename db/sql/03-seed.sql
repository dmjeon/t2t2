-- 더미 데이터. 트랙 B(부록 A) 실험 구간에서도 이 정도까지만 넣는다.
-- ★ 트랙 B 는 "실데이터 적재 전"에만 수행한다 (A-0 절).
USE aadc;
INSERT INTO write_log (dc, was_host, via_l4, note)
VALUES ('DC-500', 'seed', '', 'initial seed row');
