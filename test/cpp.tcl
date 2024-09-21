set cpp [C++]
$cpp include <vector>
$cpp proc addInCpp {int a int b} int {
    std::vector<int> xs = {a, b};
    int sum = 0;
    for (int x : xs) {
        sum += x;
    }
    return sum;
}
$cpp compile
puts "10 + 3 = [addInCpp 10 3]"
