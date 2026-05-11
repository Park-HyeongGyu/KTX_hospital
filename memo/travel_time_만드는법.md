- travel time 만드는 방법
- 전반적인 framework
> For the set of all stations, $H_i$ given some region $i$, define
> $T^{\text{KTX}}_i = \min_{h \in H_i}\{T^{\text{Car}}_{i,\text{ centroid to }h} + \text{WaitPenalty(about 2-30 minutes)} + T^{\text{KTX}}_{i, \text{ }h \text{ to Seoul}}\}$  and $T^{\text{Car}}_i = T^{\text{Car}}_{i,\text{ centroid to Seoul}}$ 
> implicitly assuming that bus-travel time is not that different from car-travel time
> Then define travel time, $T_i$ by
> $T_i = min\{T^{\text{KTX}}_i, T^{\text{Car}}_i\}$
- Car travel time 만드는 방법
	- localhost로 OSRM podman container를 띄워놓음
	- R의 OSRM패키지로 시군구의 centroid -> 용산역 car travel time 계산
	- 이걸 모든 지역에 대해 반복 이러면 각 지역별 travel time이 나옴 이걸 car_travel_time.parquet and .csv로 저장
- KTX travel time 만드는 방법
	- Given some region $X$,
	- $X$의 centroid에서 30km 안에 있는 모든 역을 찾는다. 그 역들의 집합을 $S$라 하자.
	- For all $s$ in $S$, $X$의 centroid에서 $s$로 차 타고 가는 시간 (이건 OSRM으로 계산) + $s$에서 용산역 or 서울역까지(용산역으로 가지 않는 노선의 경우 서울역 사용) ktx 타고 가는 시간 (이건 그 년도의 시간표 데이터를 보고 계산한다) + wait penalty 30분
	- 이렇게 찾은 for all $s$에 대해서 가장 작은게 ktx travel time이 된다
	- 추가로 다른 칼럼으로 interval 이라는 칼럼 만들어서 선택된 노선의 평균 배차 간격이 어느정도인지도 붙여놓는다
	- 추가로 selected_station 칼럼 만들어서 위의 가장 작은 시간을 고르는 과정에서 선택된 $s$가 뭔지 붙여놓는다 

    