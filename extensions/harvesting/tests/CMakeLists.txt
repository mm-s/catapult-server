cmake_minimum_required(VERSION 3.14)

catapult_define_extension_test(harvesting test)
target_link_libraries(tests.catapult.harvesting tests.catapult.test.crypto)
