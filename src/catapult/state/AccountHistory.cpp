/**
*** Copyright (c) 2016-present,
*** Jaguar0625, gimre, BloodyRookie, Tech Bureau, Corp. All rights reserved.
***
*** This file is part of Catapult.
***
*** Catapult is free software: you can redistribute it and/or modify
*** it under the terms of the GNU Lesser General Public License as published by
*** the Free Software Foundation, either version 3 of the License, or
*** (at your option) any later version.
***
*** Catapult is distributed in the hope that it will be useful,
*** but WITHOUT ANY WARRANTY; without even the implied warranty of
*** MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
*** GNU Lesser General Public License for more details.
***
*** You should have received a copy of the GNU Lesser General Public License
*** along with Catapult. If not, see <http://www.gnu.org/licenses/>.
**/

#include "AccountHistory.h"
#include <algorithm>

namespace catapult { namespace state {

	const HeightIndexedHistoryMap<Amount>& AccountHistory::balances() const {
		return m_heightBalanceMap;
	}

	const HeightIndexedHistoryMap<Key>& AccountHistory::vrfPublicKeys() const {
		return m_heightVrfPublicKeyMap;
	}

	const HeightIndexedHistoryMap<VotingKey>& AccountHistory::votingPublicKeys() const {
		return m_heightVotingPublicKeyMap;
	}

	bool AccountHistory::anyAtLeast(Amount minAmount) const {
		return m_heightBalanceMap.anyOf([minAmount](auto amount) {
			return minAmount <= amount;
		});
	}

	void AccountHistory::add(Height height, Amount balance) {
		m_heightBalanceMap.add(height, balance);
	}

	void AccountHistory::add(Height height, const Key& vrfPublicKey) {
		m_heightVrfPublicKeyMap.add(height, vrfPublicKey);
	}

	void AccountHistory::add(Height height, const VotingKey& votingPublicKey) {
		m_heightVotingPublicKeyMap.add(height, votingPublicKey);
	}

	void AccountHistory::prune(Height height) {
		m_heightBalanceMap.prune(height);
		m_heightVrfPublicKeyMap.prune(height);
		m_heightVotingPublicKeyMap.prune(height);
	}
}}